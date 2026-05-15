//! FileDrop — WebSocket file transfer server (Windows, Wi-Fi + USB).

use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::{Path, PathBuf},
    sync::Arc,
};

use futures_util::{SinkExt, StreamExt};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use tokio::{
    fs::{File, OpenOptions},
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::broadcast,
};
use tokio_tungstenite::{
    accept_hdr_async,
    tungstenite::{
        handshake::server::{Request, Response},
        Message,
    },
};

const CHUNK_SIZE: usize = 64 * 1024;
const DEFAULT_PORT: u16 = 8765;
const DEFAULT_OUTPUT_DIR: &str = r"C:\FileDrop\received";
const MDNS_SERVICE_TYPE: &str = "_filedrop._tcp.local.";
const MDNS_INSTANCE: &str = "FileDrop-PC";

// ---------------------------------------------------------------------------
// Config & networking
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Config {
    port: u16,
    output_dir: PathBuf,
}

impl Config {
    fn from_env() -> Self {
        let port = std::env::var("FILEDROP_PORT")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(DEFAULT_PORT);
        let output_dir = std::env::var("FILEDROP_OUTPUT_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(DEFAULT_OUTPUT_DIR));
        Self { port, output_dir }
    }
}

fn detect_lan_ipv4() -> Option<Ipv4Addr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(v4) if !v4.is_loopback() => Some(v4),
        _ => None,
    }
}

fn hostname_label() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "filedrop-pc".into())
}

// ---------------------------------------------------------------------------
// JSON protocol
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
enum ClientAction {
    Upload { filename: String, size: u64 },
    Download { filename: String },
    List,
    Ping,
}

#[derive(Debug, Serialize)]
struct ServerEvent {
    event: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    filename: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    percent: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    files: Option<Vec<String>>,
}

impl ServerEvent {
    fn transfer_start(filename: impl Into<String>, size: u64) -> Self {
        Self {
            event: "transfer_start",
            filename: Some(filename.into()),
            size: Some(size),
            percent: None,
            message: None,
            files: None,
        }
    }

    fn transfer_progress(percent: f64) -> Self {
        Self {
            event: "transfer_progress",
            filename: None,
            size: None,
            percent: Some(percent),
            message: None,
            files: None,
        }
    }

    fn transfer_complete(filename: impl Into<String>) -> Self {
        Self {
            event: "transfer_complete",
            filename: Some(filename.into()),
            size: None,
            percent: None,
            message: None,
            files: None,
        }
    }

    fn error(message: impl Into<String>) -> Self {
        Self {
            event: "error",
            filename: None,
            size: None,
            percent: None,
            message: Some(message.into()),
            files: None,
        }
    }

    fn file_added(filename: impl Into<String>) -> Self {
        Self {
            event: "file_added",
            filename: Some(filename.into()),
            size: None,
            percent: None,
            message: None,
            files: None,
        }
    }

    fn file_list(files: Vec<String>) -> Self {
        Self {
            event: "file_list",
            filename: None,
            size: None,
            percent: None,
            message: None,
            files: Some(files),
        }
    }

    fn pong() -> Self {
        Self {
            event: "pong",
            filename: None,
            size: None,
            percent: None,
            message: None,
            files: None,
        }
    }
}

fn sanitize_filename(name: &str) -> Option<String> {
    let path = Path::new(name);
    let base = path
        .file_name()
        .or_else(|| {
            if name.contains("..") {
                return None;
            }
            Some(std::ffi::OsStr::new(name))
        })?
        .to_string_lossy();
    if base.is_empty() || base == "." || base == ".." {
        return None;
    }
    Some(base.into_owned())
}

fn upload_path(output_dir: &Path, filename: &str) -> Option<PathBuf> {
    let safe = sanitize_filename(filename)?;
    Some(output_dir.join(safe))
}

fn download_path(output_dir: &Path, filename: &str) -> Option<PathBuf> {
    let path = upload_path(output_dir, filename)?;
    let base = output_dir.canonicalize().ok()?;
    let canonical = path.canonicalize().ok()?;
    if canonical.starts_with(&base) {
        Some(path)
    } else {
        None
    }
}

async fn list_output_files(output_dir: &Path) -> Vec<String> {
    let mut names = Vec::new();
    let mut read_dir = match tokio::fs::read_dir(output_dir).await {
        Ok(rd) => rd,
        Err(_) => return names,
    };
    while let Ok(Some(entry)) = read_dir.next_entry().await {
        if entry.file_type().await.map(|t| t.is_file()).unwrap_or(false) {
            if let Some(name) = entry.file_name().to_str() {
                names.push(name.to_string());
            }
        }
    }
    names.sort();
    names
}

// ---------------------------------------------------------------------------
// Shared server state
// ---------------------------------------------------------------------------

struct AppState {
    config: Config,
    /// JSON event broadcast to all connected WebSocket clients (folder watcher).
    event_tx: broadcast::Sender<String>,
}

type SharedState = Arc<AppState>;

// ---------------------------------------------------------------------------
// WebSocket connection handler
// ---------------------------------------------------------------------------

enum SessionMode {
    Idle,
    Receiving {
        filename: String,
        expected: u64,
        received: u64,
        file: File,
    },
}

struct WsConnection {
    state: SharedState,
    session: SessionMode,
}

impl WsConnection {
    fn new(state: SharedState) -> Self {
        Self {
            state,
            session: SessionMode::Idle,
        }
    }

    async fn send_json(
        sink: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
            Message,
        >,
        event: ServerEvent,
    ) {
        if let Ok(text) = serde_json::to_string(&event) {
            let _ = sink.send(Message::Text(text.into())).await;
        }
    }

    async fn handle_text(
        &mut self,
        sink: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
            Message,
        >,
        text: &str,
    ) {
        if !matches!(self.session, SessionMode::Idle) {
            Self::send_json(
                sink,
                ServerEvent::error("Busy: finish current transfer before sending commands"),
            )
            .await;
            return;
        }

        let action: ClientAction = match serde_json::from_str(text) {
            Ok(a) => a,
            Err(e) => {
                Self::send_json(sink, ServerEvent::error(&format!("Invalid JSON: {e}"))).await;
                return;
            }
        };

        match action {
            ClientAction::Ping => Self::send_json(sink, ServerEvent::pong()).await,
            ClientAction::List => {
                let files = list_output_files(&self.state.config.output_dir).await;
                Self::send_json(sink, ServerEvent::file_list(files)).await;
            }
            ClientAction::Upload { filename, size } => {
                self.begin_upload(sink, &filename, size).await;
            }
            ClientAction::Download { filename } => {
                self.begin_download(sink, &filename).await;
            }
        }
    }

    async fn begin_upload(
        &mut self,
        sink: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
            Message,
        >,
        filename: &str,
        size: u64,
    ) {
        let Some(path) = upload_path(&self.state.config.output_dir, filename) else {
            Self::send_json(sink, ServerEvent::error("Invalid filename")).await;
            return;
        };

        let safe_name = sanitize_filename(filename).unwrap_or_default();
        let file = match OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&path)
            .await
        {
            Ok(f) => f,
            Err(e) => {
                Self::send_json(
                    sink,
                    ServerEvent::error(&format!("Cannot create file: {e}")),
                )
                .await;
                return;
            }
        };

        Self::send_json(sink, ServerEvent::transfer_start(&safe_name, size)).await;
        self.session = SessionMode::Receiving {
            filename: safe_name,
            expected: size,
            received: 0,
            file,
        };
    }

    async fn handle_binary(
        &mut self,
        sink: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
            Message,
        >,
        data: &[u8],
    ) {
        let SessionMode::Receiving {
            filename,
            expected,
            received,
            file,
        } = &mut self.session
        else {
            Self::send_json(
                sink,
                ServerEvent::error("Unexpected binary data (no upload in progress)"),
            )
            .await;
            return;
        };

        if let Err(e) = file.write_all(data).await {
            Self::send_json(sink, ServerEvent::error(&format!("Write failed: {e}"))).await;
            self.session = SessionMode::Idle;
            return;
        }

        *received += data.len() as u64;
        let percent = if *expected > 0 {
            (*received as f64 / *expected as f64) * 100.0
        } else {
            100.0
        };
        Self::send_json(sink, ServerEvent::transfer_progress(percent.min(100.0))).await;

        if *received >= *expected {
            let name = filename.clone();
            if let Err(e) = file.flush().await {
                Self::send_json(sink, ServerEvent::error(&format!("Flush failed: {e}"))).await;
            } else {
                Self::send_json(sink, ServerEvent::transfer_complete(&name)).await;
            }
            self.session = SessionMode::Idle;
        }
    }

    async fn begin_download(
        &mut self,
        sink: &mut futures_util::stream::SplitSink<
            tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
            Message,
        >,
        filename: &str,
    ) {
        let Some(path) = download_path(&self.state.config.output_dir, filename) else {
            Self::send_json(sink, ServerEvent::error("Invalid filename")).await;
            return;
        };

        let safe_name = sanitize_filename(filename).unwrap_or_default();
        let meta = match tokio::fs::metadata(&path).await {
            Ok(m) if m.is_file() => m,
            Ok(_) => {
                Self::send_json(sink, ServerEvent::error("Not a file")).await;
                return;
            }
            Err(e) => {
                Self::send_json(sink, ServerEvent::error(&format!("File not found: {e}"))).await;
                return;
            }
        };

        let size = meta.len();
        Self::send_json(sink, ServerEvent::transfer_start(&safe_name, size)).await;

        let mut file = match File::open(&path).await {
            Ok(f) => f,
            Err(e) => {
                Self::send_json(sink, ServerEvent::error(&format!("Open failed: {e}"))).await;
                return;
            }
        };

        let mut sent: u64 = 0;
        let mut buf = vec![0u8; CHUNK_SIZE];

        loop {
            let n = match file.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) => {
                    Self::send_json(sink, ServerEvent::error(&format!("Read failed: {e}"))).await;
                    return;
                }
            };

            if sink.send(Message::Binary(buf[..n].to_vec().into())).await.is_err() {
                return;
            }

            sent += n as u64;
            let percent = if size > 0 {
                (sent as f64 / size as f64) * 100.0
            } else {
                100.0
            };
            Self::send_json(sink, ServerEvent::transfer_progress(percent.min(100.0))).await;
        }

        Self::send_json(sink, ServerEvent::transfer_complete(&safe_name)).await;
    }
}

async fn handle_connection(stream: tokio::net::TcpStream, state: SharedState) {
    let peer = stream
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "unknown".into());

    let ws_stream = match accept_hdr_async(stream, |req: &Request, mut resp: Response| {
        // CORS: allow all origins on the WebSocket upgrade response.
        if let Some(origin) = req.headers().get("Origin") {
            resp.headers_mut()
                .insert("Access-Control-Allow-Origin", origin.clone());
        } else {
            resp.headers_mut().insert(
                "Access-Control-Allow-Origin",
                "*".parse().unwrap(),
            );
        }
        resp.headers_mut().insert(
            "Access-Control-Allow-Methods",
            "GET, POST, OPTIONS".parse().unwrap(),
        );
        resp.headers_mut().insert(
            "Access-Control-Allow-Headers",
            "Content-Type, Authorization".parse().unwrap(),
        );
        Ok(resp)
    })
    .await
    {
        Ok(ws) => ws,
        Err(e) => {
            eprintln!("[ws] handshake failed ({peer}): {e}");
            return;
        }
    };

    println!("[ws] connected: {peer}");
    let (mut sink, mut stream) = ws_stream.split();
    let mut conn = WsConnection::new(state.clone());
    let mut folder_events = state.event_tx.subscribe();

    loop {
        tokio::select! {
            msg = stream.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        conn.handle_text(&mut sink, &text).await;
                    }
                    Some(Ok(Message::Binary(data))) => {
                        conn.handle_binary(&mut sink, &data).await;
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        let _ = sink.send(Message::Pong(payload)).await;
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(e)) => {
                        eprintln!("[ws] error ({peer}): {e}");
                        break;
                    }
                    _ => {}
                }
            }
            evt = folder_events.recv() => {
                if let Ok(json) = evt {
                    let _ = sink.send(Message::Text(json.into())).await;
                }
            }
        }
    }

    println!("[ws] disconnected: {peer}");
}

// ---------------------------------------------------------------------------
// mDNS
// ---------------------------------------------------------------------------

fn start_mdns(lan_ip: Ipv4Addr, port: u16) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let daemon = ServiceDaemon::new()?;
    let host = format!("{}.local.", hostname_label());
    let properties: HashMap<String, String> = HashMap::from([
        ("protocol".into(), "websocket".into()),
        ("path".into(), "/".into()),
    ]);

    let service_info = ServiceInfo::new(
        MDNS_SERVICE_TYPE,
        MDNS_INSTANCE,
        &host,
        [IpAddr::V4(lan_ip)].as_slice(),
        port,
        Some(properties),
    )?
    .enable_addr_auto();

    daemon.register(service_info)?;
    println!("[mdns] broadcasting {MDNS_SERVICE_TYPE} as \"{MDNS_INSTANCE}\" on port {port}");
    Ok(())
}

// ---------------------------------------------------------------------------
// Folder watcher (notify)
// ---------------------------------------------------------------------------

fn spawn_folder_watcher(output_dir: PathBuf, event_tx: broadcast::Sender<String>) {
    std::thread::spawn(move || {
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher: RecommendedWatcher = Watcher::new(tx, notify::Config::default())
            .expect("failed to create folder watcher");
        watcher
            .watch(&output_dir, RecursiveMode::NonRecursive)
            .expect("failed to watch output directory");

        println!("[watch] monitoring {}", output_dir.display());

        for res in rx {
            let Ok(event) = res else { continue };
            if !matches!(
                event.kind,
                EventKind::Create(_) | EventKind::Modify(_)
            ) {
                continue;
            }
            for path in event.paths {
                if path.is_file() {
                    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                        let payload = serde_json::to_string(&ServerEvent::file_added(name))
                            .unwrap_or_default();
                        let _ = event_tx.send(payload);
                    }
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// Listeners
// ---------------------------------------------------------------------------

async fn run_listener(addr: SocketAddr, state: SharedState, label: &'static str) {
    let listener = match TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[{label}] failed to bind {addr}: {e}");
            return;
        }
    };
    println!("[{label}] listening on ws://{addr}/");

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let state = state.clone();
                tokio::spawn(handle_connection(stream, state));
            }
            Err(e) => eprintln!("[{label}] accept error: {e}"),
        }
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let config = Config::from_env();
    tokio::fs::create_dir_all(&config.output_dir).await?;

    let lan_ip = detect_lan_ipv4().unwrap_or(Ipv4Addr::new(0, 0, 0, 0));
    let usb_ip = Ipv4Addr::LOCALHOST;
    let port = config.port;

    println!("=== FileDrop Server ===");
    println!("LAN IP (Wi-Fi):  {lan_ip}");
    println!("USB IP:           {usb_ip}  (use: iproxy {port} {port})");
    println!("Port:             {port}");
    println!("Output directory: {}", config.output_dir.display());
    println!();
    println!("FileDrop server running. Connect your iPhone to the same Wi-Fi or via USB.");
    println!();

    if lan_ip != Ipv4Addr::new(0, 0, 0, 0) {
        if let Err(e) = start_mdns(lan_ip, port) {
            eprintln!("[mdns] warning: could not start mDNS ({e})");
        }
    } else {
        eprintln!("[mdns] skipped — no LAN IPv4 detected");
    }

    let (event_tx, _) = broadcast::channel::<String>(64);
    spawn_folder_watcher(config.output_dir.clone(), event_tx.clone());

    let state = Arc::new(AppState {
        config: config.clone(),
        event_tx,
    });

    let lan_addr = SocketAddr::new(IpAddr::V4(lan_ip), port);
    let usb_addr = SocketAddr::new(IpAddr::V4(usb_ip), port);

    let state_lan = state.clone();
    let state_usb = state.clone();

    let lan_handle = tokio::spawn(async move {
        if lan_ip != Ipv4Addr::new(0, 0, 0, 0) {
            run_listener(lan_addr, state_lan, "wifi").await;
        }
    });

    let usb_handle = tokio::spawn(async move {
        run_listener(usb_addr, state_usb, "usb").await;
    });

    // Keep process alive; if one listener dies, the other continues.
    tokio::select! {
        _ = lan_handle => {},
        _ = usb_handle => {},
    }

    Ok(())
}
