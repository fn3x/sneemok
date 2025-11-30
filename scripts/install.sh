#!/usr/bin/bash

set -euo pipefail

REPO="fn3x/sneemok"
BINARY_NAME="sneemok"
TEMP_DIR="/tmp"
SYSTEMD_SERVICE_NAME="sneemok.service"

# Installation prefix - can be overridden via environment or --prefix flag
PREFIX="${PREFIX:-/usr/local}"

INSTALL_DIR="$PREFIX/lib/sneemok"
BIN_DIR="$PREFIX/bin"
APPLICATIONS_DIR="$PREFIX/share/applications"
SYSTEMD_USER_DIR="$PREFIX/lib/systemd/user"

SNEEMOK_SCRIPT_PATH="$TEMP_DIR/sneemok-install-script.sh"
SCRIPT_DOWNLOAD_URL="https://codeberg.org/$REPO/raw/branch/main/scripts/install.sh"
DOCS_URL="https://codeberg.org/$REPO"

TEMP_FILES=()
PRESERVE_FILES=()

cleanup() {
	rm -f "$SNEEMOK_SCRIPT_PATH"
	for file in "${TEMP_FILES[@]}"; do
		if [[ -e "$file" ]]; then
			rm -rf "$file"
		fi
	done
}

trap cleanup EXIT ERR

renderIcon() {
	cols=$(tput cols)

	icon=$(
		cat <<'EOF'
                                         ______  
_______________________________ ____________  /__
__  ___/_  __ \  _ \  _ \_  __ `__ \  __ \_  //_/
_(__  )_  / / /  __/  __/  / / / / / /_/ /  ,<   
/____/ /_/ /_/\___/\___//_/ /_/ /_/\____//_/|_|  
EOF
	)

	tagline="Wayland screenshot annotation tool"

	while IFS= read -r line; do
		line_len=${#line}
		padding=$(((cols - line_len) / 2))
		printf "%*s%s\n" "$padding" "" "$line"
	done <<<"$icon"

	echo

	tagline_len=${#tagline}
	padding=$(((cols - tagline_len) / 2))
	printf "%*s%s\n\n" "$padding" "" "$tagline"
}

check_dependencies() {
	echo "Checking dependencies..."

	if ! command -v curl >/dev/null 2>&1; then
		echo "Error: curl is required but not installed."
		echo "Please install curl and try again."
		exit 1
	fi

	if ! command -v jq >/dev/null 2>&1; then
		echo "Error: jq is required but not installed."
		echo "Please install jq and try again."
		exit 1
	fi

	echo "✓ All dependencies found"
}

check_permissions() {
	echo "Checking installation permissions..."

	local test_dir="$BIN_DIR"

	if [[ ! -w "$test_dir" && ! -w "$(dirname "$test_dir")" ]]; then
		echo ""
		echo "Warning: Installation to $PREFIX requires elevated permissions."
		echo ""

		if [[ $EUID -eq 0 ]]; then
			echo "✓ Running as root"
		else
			local escalation_cmd=""
			local escalation_name=""

			if command -v doas >/dev/null 2>&1; then
				escalation_cmd="doas"
				escalation_name="doas"
			elif command -v sudo >/dev/null 2>&1; then
				escalation_cmd="sudo -E"
				escalation_name="sudo"
			else
				echo "Error: Neither doas nor sudo is available."
				echo "Please install doas or sudo, or use --prefix ~/.local for a user installation."
				exit 1
			fi

			echo "This script will need root privileges in order to install to $PREFIX"
			echo ""
			echo "You have the following options:"
			echo "  1. Re-run this script with $escalation_name: we will prompt you for your password (recommended)"
			echo "  2. Install to a custom, local directory: use --prefix ~/.local"
			echo ""
			read -p "Would you like to continue with $escalation_name? [y/N] " -n 1 -r </dev/tty
			echo

			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				echo "Installation cancelled."
				exit 0
			fi

			echo "Re-downloading script to execute with elevated privileges..."
			self_download

			# Re-execute with privilege escalation
			echo "Re-executing with $escalation_name..."
			exec $escalation_cmd "$SNEEMOK_SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
		fi
	else
		echo "✓ Have write permissions to $PREFIX"
	fi
}

get_latest_release_info() {
	echo "Fetching latest release info from Codeberg..." >&2
	local api_url="https://codeberg.org/api/v1/repos/$REPO/releases/latest"

	local response
	response=$(curl -s "$api_url")

	local tag_name
	tag_name=$(echo "$response" | jq -r '.tag_name')

	if [[ "$tag_name" == "null" || -z "$tag_name" ]]; then
		echo "Error: Failed to fetch latest version from Codeberg API" >&2
		exit 1
	fi

	local tarball_name
	tarball_name=$(echo "$response" | jq -r '.assets[] | select(.name | contains("x86_64-linux.tar.gz")) | .name')

	if [[ "$tarball_name" == "null" || -z "$tarball_name" ]]; then
		echo "Error: Failed to find binary tarball in latest release" >&2
		echo "Note: This script installs pre-built binaries. To build from source, see:" >&2
		echo "      $DOCS_URL" >&2
		exit 1
	fi

	echo "✓ Latest version: $tag_name" >&2
	echo "✓ Binary tarball: $tarball_name" >&2
	echo "$tag_name|$tarball_name"
}

get_installed_version() {
	if [[ ! -f "$BIN_DIR/$BINARY_NAME" ]]; then
		echo "none"
		return
	fi

	local version_output
	if version_output=$("$BIN_DIR/$BINARY_NAME" --version 2>/dev/null); then
		local version
		version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		if [[ -n "$version" ]]; then
			echo "v$version"
		else
			echo "unknown"
		fi
	else
		echo "unknown"
	fi
}

compare_versions() {
	local installed="$1"
	local latest="$2"

	if [[ "$installed" == "none" || "$installed" == "unknown" ]]; then
		return 0 # Need to install
	fi

	local installed_clean="${installed#v}"
	local latest_clean="${latest#v}"

	if [[ "$installed_clean" != "$latest_clean" ]]; then
		return 0 # Need to update
	fi

	return 1 # Already up to date
}

download_tarball() {
	local version="$1"
	local tarball_name="$2"
	local download_path="$TEMP_DIR/$tarball_name"
	local download_url="https://codeberg.org/$REPO/releases/download/$version/$tarball_name"

	if [[ -f "$download_path" ]]; then
		echo "✓ Using cached tarball: $download_path" >&2
		PRESERVE_FILES+=("$download_path")
		echo "$download_path"
		return 0
	fi

	echo "Downloading Sneemok $version..." >&2
	echo "Asset: $tarball_name" >&2
	echo "URL: $download_url" >&2

	if curl -L --progress-bar "$download_url" -o "$download_path"; then
		PRESERVE_FILES+=("$download_path") # Keep for future runs
		echo "✓ Download completed: $download_path" >&2
		echo "$download_path"
	else
		echo "Error: Failed to download tarball" >&2
		exit 1
	fi
}

extract_tarball() {
	local tarball_path="$1"
	local extract_dir="$TEMP_DIR/sneemok-extract-$$"

	echo "Extracting tarball..." >&2

	rm -rf "$extract_dir"
	mkdir -p "$extract_dir"

	if tar xzf "$tarball_path" -C "$extract_dir" --strip-components=1; then
		echo "✓ Extraction completed" >&2
		echo "$extract_dir"
		TEMP_FILES+=("$extract_dir")
	else
		echo "Error: Failed to extract tarball" >&2
		exit 1
	fi
}

install_desktop_file() {
	echo "Installing desktop application file..." >&2

	mkdir -p "$APPLICATIONS_DIR"

	local desktop_file="$APPLICATIONS_DIR/sneemok.desktop"

	cat >"$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=Sneemok
Comment=Wayland screenshot annotation tool
Exec=$BIN_DIR/$BINARY_NAME
Icon=camera-photo
Terminal=false
Categories=Utility;Graphics;
Keywords=screenshot;capture;annotate;
EOF

	chmod 644 "$desktop_file"
	echo "✓ Desktop file installed to $desktop_file" >&2

	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
		echo "✓ Desktop database updated" >&2
	fi
}

install_systemd_service() {
	echo "Installing systemd user service..." >&2

	mkdir -p "$SYSTEMD_USER_DIR"

	local service_file="$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE_NAME"

	cat >"$service_file" <<EOF
[Unit]
Description=Sneemok Screenshot Annotation Tool
Documentation=$DOCS_URL
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$BIN_DIR/$BINARY_NAME --daemon
Restart=on-failure
RestartSec=5

# Security hardening
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
NoNewPrivileges=yes

[Install]
WantedBy=graphical-session.target
EOF

	chmod 644 "$service_file"
	echo "✓ Systemd service installed to $service_file" >&2

	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user daemon-reload 2>/dev/null || true
		echo "✓ Systemd user daemon reloaded" >&2
	fi
}

install_sneemok() {
	local extract_dir="$1"

	echo "Installing Sneemok..." >&2

	mkdir -p "$BIN_DIR"
	mkdir -p "$INSTALL_DIR"

	local binary_path="$extract_dir/$BINARY_NAME"

	if [[ ! -f "$binary_path" ]]; then
		echo "Error: Sneemok binary not found in extracted files" >&2
		echo "Looking in: $extract_dir" >&2
		ls -la "$extract_dir/" 2>&1 | head -10 >&2
		exit 1
	fi

	cp "$binary_path" "$INSTALL_DIR/$BINARY_NAME"
	chmod 755 "$INSTALL_DIR/$BINARY_NAME"

	# Create symlink in bin directory
	ln -sf "$INSTALL_DIR/$BINARY_NAME" "$BIN_DIR/$BINARY_NAME"

	echo "✓ Binary installed to $INSTALL_DIR/$BINARY_NAME" >&2
	echo "✓ Symlink created at $BIN_DIR/$BINARY_NAME" >&2

	install_desktop_file
	install_systemd_service

	echo "✓ Installation completed" >&2
}

uninstall_sneemok() {
	echo "Uninstalling Sneemok..."

	if [[ -d "$INSTALL_DIR" ]]; then
		rm -rf "$INSTALL_DIR"
		echo "✓ Removed installation directory: $INSTALL_DIR"
	else
		echo "No installation directory found"
	fi

	if [[ -L "$BIN_DIR/$BINARY_NAME" ]]; then
		rm -f "$BIN_DIR/$BINARY_NAME"
		echo "✓ Removed binary symlink: $BIN_DIR/$BINARY_NAME"
	else
		echo "No binary symlink found"
	fi

	if [[ -f "$APPLICATIONS_DIR/sneemok.desktop" ]]; then
		rm -f "$APPLICATIONS_DIR/sneemok.desktop"
		echo "✓ Removed desktop file: $APPLICATIONS_DIR/sneemok.desktop"
		if command -v update-desktop-database >/dev/null 2>&1; then
			update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
		fi
	fi

	if [[ -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE_NAME" ]]; then
		if command -v systemctl >/dev/null 2>&1; then
			systemctl --user stop "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
			systemctl --user disable "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
		fi
		rm -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE_NAME"
		echo "✓ Removed systemd service: $SYSTEMD_USER_DIR/$SYSTEMD_SERVICE_NAME"
		if command -v systemctl >/dev/null 2>&1; then
			systemctl --user daemon-reload 2>/dev/null || true
		fi
	fi

	echo "✓ Sneemok has been uninstalled"
}

show_usage() {
	echo "Usage: $0 [OPTIONS]"
	echo ""
	echo "Options:"
	echo "  --prefix PATH  Installation prefix (default: /usr/local)"
	echo "  --uninstall    Uninstall Sneemok"
	echo "  --help, -h     Show this help message"
	echo ""
	echo "Environment variables:"
	echo "  PREFIX         Installation prefix (overridden by --prefix)"
	echo ""
	echo "Without options, the script will install or update Sneemok to the latest version."
	echo ""
	echo "Examples:"
	echo "  $0                           # Install to /usr/local (requires sudo)"
	echo "  $0 --prefix ~/.local         # Install to ~/.local (user install)"
	echo "  PREFIX=/opt/sneemok $0       # Install to /opt/sneemok"
	echo ""
	echo "After installation:"
	echo "  sneemok --daemon                       # Start daemon"
	echo "  sneemok --screenshot                   # Take screenshot"
	echo "  systemctl --user enable --now sneemok  # Enable service"
}

self_download() {
	curl -fsSL "$SCRIPT_DOWNLOAD_URL" >"$SNEEMOK_SCRIPT_PATH"
	chmod +x "$SNEEMOK_SCRIPT_PATH"
}

main() {
	renderIcon

	# Save original arguments for potential re-execution with sudo/doas
	ORIGINAL_ARGS=("$@")

	# Parse arguments
	local action=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prefix)
			if [[ -z "${2:-}" ]]; then
				echo "Error: --prefix requires a path argument"
				show_usage
				exit 1
			fi
			PREFIX="$2"
			# Recalculate derived paths
			INSTALL_DIR="$PREFIX/lib/sneemok"
			BIN_DIR="$PREFIX/bin"
			APPLICATIONS_DIR="$PREFIX/share/applications"
			SYSTEMD_USER_DIR="$PREFIX/lib/systemd/user"
			shift 2
			;;
		--uninstall)
			action="uninstall"
			shift
			;;
		--help | -h)
			show_usage
			exit 0
			;;
		*)
			echo "Error: Unknown option '$1'"
			show_usage
			exit 1
			;;
		esac
	done

	if [[ "$action" == "uninstall" ]]; then
		check_permissions
		uninstall_sneemok
		exit 0
	fi

	mkdir -p "$PREFIX"
	check_dependencies
	check_permissions

	local release_info
	release_info=$(get_latest_release_info)

	local latest_version
	local tarball_name
	IFS='|' read -r latest_version tarball_name <<<"$release_info"

	local installed_version
	installed_version=$(get_installed_version)

	echo "Installed version: $installed_version"
	echo "Latest version: $latest_version"

	if compare_versions "$installed_version" "$latest_version"; then
		if [[ "$installed_version" == "none" ]]; then
			echo "Installing Sneemok for the first time..."
		else
			echo "Updating Sneemok from $installed_version to $latest_version..."
		fi

		local tarball_path
		tarball_path=$(download_tarball "$latest_version" "$tarball_name")

		local extract_dir
		extract_dir=$(extract_tarball "$tarball_path")

		install_sneemok "$extract_dir"

		echo ""
		echo "🎉 Sneemok $latest_version has been successfully installed!"
		echo ""

		if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
			echo "✓ $BIN_DIR is already in your PATH"
			echo "You can now run 'sneemok' from anywhere in your terminal."
		else
			echo "To use Sneemok, add $BIN_DIR to your PATH:"
			if [[ "$BIN_DIR" == "$HOME"* ]]; then
				local_path="${BIN_DIR/#$HOME/\$HOME}"
				echo "  export PATH=\"$local_path:\$PATH\""
			else
				echo "  export PATH=\"$BIN_DIR:\$PATH\""
			fi
			echo ""
			echo "You can add this to your shell profile (~/.bashrc, ~/.zshrc, etc.) for permanent access."
			echo "Then restart your terminal or run the export command above."
		fi

		echo ""
		echo "Quick start:"
		echo "  sneemok --daemon             # Start daemon in background"
		echo "  sneemok [--screenshot]       # Take a screenshot"
		echo ""
		echo "Enable systemd service (optional):"
		echo "  systemctl --user enable --now sneemok"
		echo ""
		echo "Add to your compositor keybindings:"
		echo "  # Hyprland:"
		echo "  bind = \$mainMod, P, exec, sneemok"
		echo ""
		echo "  # i3/sway:"
		echo "  bindsym \$mod+p exec sneemok"
		echo ""
		echo "Documentation: $DOCS_URL"
	else
		echo "✓ Sneemok is already up to date ($installed_version)"
	fi
}

main "$@"
