# FileBrowser Automated Setup Script

Builds [FileBrowser](https://github.com/filebrowser/filebrowser) from source and installs it as a systemd service. The script installs Go (1.22 or newer), Node.js, pnpm and Task for you.

## Automatic Install

```bash
bash filebrowser-install.sh
```

The script asks for an install directory (default `/opt/filebrowser`), a port (default `8082`) and the folder to share (default `/srv/files`). When it finishes, open `http://<server-ip>:8082`.

**Default login:** `admin` / `admin12345678`. Change the password the first time you sign in (it needs at least 12 characters).

The binary goes in `/usr/local/bin/filebrowser`. On Fedora with SELinux the script sets the right label on it, and if firewalld is running it opens the port.

## Service

```bash
sudo systemctl status filebrowser
sudo systemctl restart filebrowser
sudo systemctl stop filebrowser
```

## Uninstall

```bash
bash filebrowser-install.sh uninstall
```

This removes the service and binary, and asks before removing the install folder, the build folder, Go and the build packages. Your shared files folder is not removed.

## Supported Distros

| Distro | Status |
|---|---|
| Fedora | Tested, works |
| Debian / Ubuntu (and Mint, Pop!_OS, Zorin, elementary) | Not tested, need feedback |
| RHEL / Rocky / AlmaLinux / CentOS | Not tested, need feedback |
| Arch / Manjaro / EndeavourOS / Garuda | Not tested, need feedback |
| openSUSE / SLES | Not tested, need feedback |
| Alpine | Not tested, need feedback |

If you try it on a distro that isn't tested, please open an issue and say how it went.
