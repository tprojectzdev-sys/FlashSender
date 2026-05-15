@echo off
echo Building FileDrop server...
cargo build --release --manifest-path server\Cargo.toml
if errorlevel 1 (
    echo Build failed.
    pause
    exit /b 1
)
echo.
echo Starting FileDrop server...
echo NOTE: Allow this app through Windows Firewall if prompted.
echo.
server\target\release\filedrop-server.exe
pause
