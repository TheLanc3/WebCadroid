#!/usr/bin/env bash

# ==============================================================================
# WebCadroid Release Build Automation Script
# Builds WebCadroid (WPF / .NET 10 desktop) and WebCadroidClient (Flutter / Android)
# ==============================================================================

set -euo pipefail

# Text formatting
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
DIST_DIR="$SCRIPT_DIR/dist"
PC_PROJECT="$SRC_DIR/WebCadroid/WebCadroid.csproj"
CLIENT_DIR="$SRC_DIR/WebCadroidClient"

# Default build options
BUILD_PC=true
BUILD_CLIENT=true
BUILD_BUNDLE=false
CLEAN_BUILD=false
SKIP_TESTS=false

# Print header
echo -e "${BLUE}${BOLD}====================================================${NC}"
echo -e "${BLUE}${BOLD}           WebCadroid Release Build Tool            ${NC}"
echo -e "${BLUE}${BOLD}====================================================${NC}"

# Usage help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --all            Build both desktop and Android apps (default)
  --pc, --desktop  Build only the desktop app (WebCadroid WPF / .NET)
  --client, --apk  Build only the Android app (WebCadroidClient Flutter APK)
  --bundle         Also build Android App Bundle (.aab)
  --clean          Clean previous build artifacts before building
  --skip-tests     Skip running unit tests and linters before building
  -h, --help       Show this help message
EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            BUILD_PC=true
            BUILD_CLIENT=true
            shift
            ;;
        --pc|--desktop)
            BUILD_PC=true
            BUILD_CLIENT=false
            shift
            ;;
        --client|--apk)
            BUILD_PC=false
            BUILD_CLIENT=true
            shift
            ;;
        --bundle)
            BUILD_BUNDLE=true
            shift
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Check required tools
check_requirements() {
    echo -e "\n${BLUE}--> Checking prerequisites...${NC}"
    
    if [ "$BUILD_PC" = true ]; then
        if ! command -v dotnet >/dev/null 2>&1; then
            echo -e "${RED}Error: .NET SDK (dotnet) is not installed or not in PATH.${NC}"
            exit 1
        fi
        echo -e "  [x] .NET SDK: $(dotnet --version)"
    fi

    if [ "$BUILD_CLIENT" = true ]; then
        if ! command -v flutter >/dev/null 2>&1; then
            echo -e "${RED}Error: Flutter SDK (flutter) is not installed or not in PATH.${NC}"
            exit 1
        fi
        echo -e "  [x] Flutter SDK: $(flutter --version | head -n 1)"
    fi
}

# Clean output directories if requested
clean_outputs() {
    if [ "$CLEAN_BUILD" = true ]; then
        echo -e "\n${YELLOW}--> Cleaning build directories...${NC}"
        if [ "$BUILD_PC" = true ]; then
            dotnet clean "$PC_PROJECT" -c Release >/dev/null 2>&1 || true
            rm -rf "$DIST_DIR/WebCadroid"
        fi
        if [ "$BUILD_CLIENT" = true ]; then
            (cd "$CLIENT_DIR" && flutter clean >/dev/null 2>&1 || true)
            rm -rf "$DIST_DIR/WebCadroidClient"
        fi
        echo -e "  ${GREEN}Clean completed.${NC}"
    fi
}

# Run tests and linters
run_tests() {
    if [ "$SKIP_TESTS" = false ]; then
        echo -e "\n${BLUE}--> Running tests & code analysis...${NC}"

        if [ "$BUILD_CLIENT" = true ]; then
            echo -e "  * Analyzing Flutter client..."
            (cd "$CLIENT_DIR" && flutter analyze)
            echo -e "  * Running Flutter unit/widget tests..."
            (cd "$CLIENT_DIR" && flutter test)
        fi

        if [ "$BUILD_PC" = true ]; then
            echo -e "  * Verifying .NET desktop build..."
            dotnet build "$PC_PROJECT" -c Release --no-incremental >/dev/null
        fi

        echo -e "  ${GREEN}All checks passed successfully.${NC}"
    fi
}

# Build WebCadroid (WPF / .NET 10 desktop app)
build_desktop() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE}  Building WebCadroid (Windows Desktop .NET Release) ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    mkdir -p "$DIST_DIR/WebCadroid"

    dotnet publish "$PC_PROJECT" \
        -c Release \
        -r win-x64 \
        --self-contained true \
        -o "$DIST_DIR/WebCadroid"

    echo -e "${GREEN}Desktop build completed successfully!${NC}"
}

# Build WebCadroidClient (Flutter Android APK & Bundle)
build_client() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE}  Building WebCadroidClient (Flutter Android Release)${NC}"
    echo -e "${BLUE}====================================================${NC}"

    mkdir -p "$DIST_DIR/WebCadroidClient"

    (
        cd "$CLIENT_DIR"
        echo -e "  * Fetching Flutter dependencies..."
        flutter pub get

        echo -e "  * Compiling release APK..."
        flutter build apk --release

        APK_SRC="build/app/outputs/flutter-apk/app-release.apk"
        if [ -f "$APK_SRC" ]; then
            cp "$APK_SRC" "$DIST_DIR/WebCadroidClient/WebCadroidClient.apk"
        fi

        if [ "$BUILD_BUNDLE" = true ]; then
            echo -e "  * Compiling release App Bundle (.aab)..."
            flutter build appbundle --release
            AAB_SRC="build/app/outputs/bundle/release/app-release.aab"
            if [ -f "$AAB_SRC" ]; then
                cp "$AAB_SRC" "$DIST_DIR/WebCadroidClient/WebCadroidClient.aab"
            fi
        fi
    )

    echo -e "${GREEN}Android client build completed successfully!${NC}"
}

# Print summary
print_summary() {
    echo -e "\n${GREEN}${BOLD}====================================================${NC}"
    echo -e "${GREEN}${BOLD}             BUILD FINISHED SUCCESSFULLY!           ${NC}"
    echo -e "${GREEN}${BOLD}====================================================${NC}"
    echo -e "Artifacts available in: ${BOLD}$DIST_DIR${NC}\n"

    if [ "$BUILD_PC" = true ] && [ -d "$DIST_DIR/WebCadroid" ]; then
        echo -e "${BLUE}Desktop Artifacts:${NC}"
        if [ -f "$DIST_DIR/WebCadroid/WebCadroid.exe" ]; then
            EXE_SIZE=$(du -h "$DIST_DIR/WebCadroid/WebCadroid.exe" | cut -f1)
            echo -e "  * $DIST_DIR/WebCadroid/WebCadroid.exe ($EXE_SIZE)"
            echo -e "  * $DIST_DIR/WebCadroid/Utils/ (Native drivers & tools)"
        fi
    fi

    if [ "$BUILD_CLIENT" = true ] && [ -d "$DIST_DIR/WebCadroidClient" ]; then
        echo -e "\n${BLUE}Android Artifacts:${NC}"
        if [ -f "$DIST_DIR/WebCadroidClient/WebCadroidClient.apk" ]; then
            APK_SIZE=$(du -h "$DIST_DIR/WebCadroidClient/WebCadroidClient.apk" | cut -f1)
            echo -e "  * $DIST_DIR/WebCadroidClient/WebCadroidClient.apk ($APK_SIZE)"
        fi
        if [ -f "$DIST_DIR/WebCadroidClient/WebCadroidClient.aab" ]; then
            AAB_SIZE=$(du -h "$DIST_DIR/WebCadroidClient/WebCadroidClient.aab" | cut -f1)
            echo -e "  * $DIST_DIR/WebCadroidClient/WebCadroidClient.aab ($AAB_SIZE)"
        fi
    fi
    echo ""
}

# Main execution flow
check_requirements
clean_outputs
run_tests

if [ "$BUILD_PC" = true ]; then
    build_desktop
fi

if [ "$BUILD_CLIENT" = true ]; then
    build_client
fi

print_summary
