#!/usr/bin/env bash
# shellcheck disable=SC2128,SC2178

# Tell build process to exit if there are any errors.
set -euo pipefail

get_json_array INSTALL 'try .["install"][]' "$1"

if [[ ${#INSTALL[@]} -lt 1 ]]; then
  echo "ERROR: You did not specify the extension to install in module recipe file"
  exit 1
fi

if ! command -v gnome-shell &> /dev/null; then 
  echo "ERROR: Your custom image is using non-Gnome desktop environment, where Gnome extensions are not supported"
  exit 1
fi

echo "Testing connection with https://extensions.gnome.org/..."
if ! curl --output /dev/null --silent --head --fail "https://extensions.gnome.org/"; then
  echo "ERROR: Connection unsuccessful."
  echo "       This usually happens when https://extensions.gnome.org/ website is down."
  echo "       Please try again later (or disable the module temporarily)"
  exit 1
else
  echo "Connection successful, proceeding."
fi  


GNOME_VER=$(gnome-shell --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')
echo "Gnome version: ${GNOME_VER}"

for INSTALL_EXT in "${INSTALL[@]}"; do
    if [[ ! "${INSTALL_EXT}" =~ ^[0-9]+$ ]]; then
      # Literal-name extension config
      # Replaces whitespaces with %20 for install entries which contain extension name, since URLs can't contain whitespace      
      WHITESPACE_HTML="${INSTALL_EXT// /%20}"
      URL_QUERY=$(curl -sf "https://extensions.gnome.org/extension-query/?search=${WHITESPACE_HTML}")
      QUERIED_EXT=$(echo "${URL_QUERY}" | jq ".extensions[] | select(.name == \"${INSTALL_EXT}\")")
      if [[ -z "${QUERIED_EXT}" ]] || [[ "${QUERIED_EXT}" == "null" ]]; then
        echo "ERROR: Extension '${INSTALL_EXT}' does not exist in https://extensions.gnome.org/ website"
        echo "       Extension name is case-sensitive, so be sure that you typed it correctly,"
        echo "       including the correct uppercase & lowercase characters"
        exit 1
      fi
      readarray -t EXT_UUID < <(echo "${QUERIED_EXT}" | jq -r '.["uuid"]')
      readarray -t EXT_NAME < <(echo "${QUERIED_EXT}" | jq -r '.["name"]')
      if [[ ${#EXT_UUID[@]} -gt 1 ]] || [[ ${#EXT_NAME[@]} -gt 1 ]]; then
        echo "ERROR: Multiple compatible Gnome extensions with the same name are found, which this module cannot select"
        echo "       To solve this problem, please use PK ID as a module input entry instead of the extension name"
        echo "       You can get PK ID from the extension URL, like from Blur my Shell's 3193 PK ID example below:"
        echo "       https://extensions.gnome.org/extension/3193/blur-my-shell/"
        exit 1
      fi        
      # Gets latest extension version for latest available Gnome version
      SUITABLE_VERSION=$(echo "${QUERIED_EXT}" | jq -r '.shell_version_map | to_entries | max_by(.key | tonumber) | .value.version')
    else
      # PK ID extension config fallback if specified
      URL_QUERY=$(curl -sf "https://extensions.gnome.org/extension-info/?pk=${INSTALL_EXT}")
      PK_EXT=$(echo "${URL_QUERY}" | jq -r '.["pk"]' 2>/dev/null)
      if [[ -z "${PK_EXT}" ]] || [[ "${PK_EXT}" == "null" ]]; then
        echo "ERROR: Extension with PK ID '${INSTALL_EXT}' does not exist in https://extensions.gnome.org/ website"
        echo "       Please assure that you typed the PK ID correctly,"
        echo "       and that it exists in Gnome extensions website"
        exit 1
      fi
      EXT_UUID=$(echo "${URL_QUERY}" | jq -r '.["uuid"]')
      EXT_NAME=$(echo "${URL_QUERY}" | jq -r '.["name"]')
      # Gets latest extension version for latest available Gnome version
      SUITABLE_VERSION=$(echo "${URL_QUERY}" | jq -r '.shell_version_map | to_entries | max_by(.key | tonumber) | .value.version')
    fi  
    # Removes every @ symbol from UUID, since extension URL doesn't contain @ symbol
    URL="https://extensions.gnome.org/extension-data/${EXT_UUID//@/}.v${SUITABLE_VERSION}.shell-extension.zip"
    TMP_DIR="/tmp/${EXT_UUID}"
    ARCHIVE=$(basename "${URL}")
    ARCHIVE_DIR="${TMP_DIR}/${ARCHIVE}"
    echo "Installing '${EXT_NAME}' Gnome extension with version ${SUITABLE_VERSION}"
    # Download archive
    echo "Downloading ZIP archive ${URL}"
    curl -fLs --create-dirs "${URL}" -o "${ARCHIVE_DIR}"
    echo "Downloaded ZIP archive ${URL}"
    # Extract archive
    echo "Extracting ZIP archive"
    unzip "${ARCHIVE_DIR}" -d "${TMP_DIR}" > /dev/null
    # Remove archive
    echo "Removing archive"
    rm "${ARCHIVE_DIR}"
    # Install main extension files
    echo "Installing main extension files"
    install -d -m 0755 "/usr/share/gnome-shell/extensions/${EXT_UUID}/"
    find "${TMP_DIR}" -mindepth 1 -maxdepth 1 ! -path "*locale*" ! -path "*schemas*" -exec cp -r {} "/usr/share/gnome-shell/extensions/${EXT_UUID}/" \;
    find "/usr/share/gnome-shell/extensions/${EXT_UUID}" -type d -exec chmod 0755 {} +
    find "/usr/share/gnome-shell/extensions/${EXT_UUID}" -type f -exec chmod 0644 {} +
    # Install schema
    if [[ -d "${TMP_DIR}/schemas" ]]; then
      echo "Installing schema extension file"
      # Workaround for extensions, which explicitly require compiled schema to be in extension UUID directory (rare scenario due to how extension is programmed in non-standard way)
      # Error code example:
      # GLib.FileError: Failed to open file “/usr/share/gnome-shell/extensions/flypie@schneegans.github.com/schemas/gschemas.compiled”: open() failed: No such file or directory
      # If any extension produces this error, it can be added in if statement below to solve the problem
      # Fly-Pie or PaperWM
      if [[ "${EXT_UUID}" == "flypie@schneegans.github.com" || "${EXT_UUID}" == "paperwm@paperwm.github.com" ]]; then
        install -d -m 0755 "/usr/share/gnome-shell/extensions/${EXT_UUID}/schemas/"
        install -D -p -m 0644 "${TMP_DIR}/schemas/"*.gschema.xml "/usr/share/gnome-shell/extensions/${EXT_UUID}/schemas/"
        glib-compile-schemas "/usr/share/gnome-shell/extensions/${EXT_UUID}/schemas/" &>/dev/null
      else
        # Regular schema installation
        install -d -m 0755 "/usr/share/glib-2.0/schemas/"
        install -D -p -m 0644 "${TMP_DIR}/schemas/"*.gschema.xml "/usr/share/glib-2.0/schemas/"
      fi  
    fi  
    # Install languages
    # Locale is not crucial for extensions to work, as they will fallback to gschema.xml
    # Some of them might not have any locale at the moment
    # So that's why I made a check for directory
    # I made an additional check if language files are available, in case if extension is packaged with an empty folder, like with Default Workspace extension
    if [[ -d "${TMP_DIR}/locale/" ]]; then
      if find "${TMP_DIR}/locale/" -type f -name "*.mo" -print -quit | read; then
        echo "Installing language extension files"
        install -d -m 0755 "/usr/share/locale/"
        cp -r "${TMP_DIR}/locale"/* "/usr/share/locale/"
      fi
    fi
    # Modify metadata.json to support latest Gnome version
    echo "Modifying metadata.json to support Gnome ${GNOME_VER}"      
    jq --arg gnome_ver "${GNOME_VER}" 'if (.["shell-version"] | index($gnome_ver) | not) then .["shell-version"] += [$gnome_ver] else . end' "/usr/share/gnome-shell/extensions/${EXT_UUID}/metadata.json" > "/tmp/temp-metadata.json"
    mv "/tmp/temp-metadata.json" "/usr/share/gnome-shell/extensions/${EXT_UUID}/metadata.json"
    # Delete the temporary directory
    echo "Cleaning up the temporary directory"
    rm -r "${TMP_DIR}"
    echo "Extension '${EXT_NAME}' is successfully installed"
    echo "----------------------------------INSTALLATION DONE----------------------------------"
done

# Compile gschema to include schemas from extensions  & to refresh the schema state
echo "Compiling gschema to include extension schemas & to refresh the schema state"
glib-compile-schemas "/usr/share/glib-2.0/schemas/" &>/dev/null
