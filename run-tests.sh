#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/h2c-known-versions.yaml"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"
RAW_BASE="https://raw.githubusercontent.com"
MANAGER_URL="$RAW_BASE/helmfile2compose/h2c-manager/main/h2c-manager.py"
REGISTRY_URL="$RAW_BASE/helmfile2compose/h2c-manager/main/extensions.json"
TMP_BASE="/tmp/h2c-testsuite"
MANAGER_PATH="$TMP_BASE/h2c-manager.py"

# Cleanup on exit
_CLEANUP_DIRS=()
cleanup() {
    for dir in "${_CLEANUP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
PERF_N=""
KEEP=false
CORE_OVERRIDE=""
LOCAL_CORE=""
declare -a EXT_OVERRIDES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --perf)        PERF_N="$2"; shift 2 ;;
        --core)        CORE_OVERRIDE="$2"; shift 2 ;;
        --local-core)  LOCAL_CORE="$2"; shift 2 ;;
        --ext)         EXT_OVERRIDES+=("$2"); shift 2 ;;
        --keep)        KEEP=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--core vX.Y.Z] [--local-core /path/to/helmfile2compose.py] [--ext name==vX.Y.Z ...] [--perf N] [--keep]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -n "$LOCAL_CORE" && ! -f "$LOCAL_CORE" ]]; then
    echo "Error: local core not found: $LOCAL_CORE"
    exit 1
fi

# ---------------------------------------------------------------------------
# YAML parser (no pyyaml needed)
# ---------------------------------------------------------------------------
parse_versions_file() {
    local section=""
    REF_CORE=""
    declare -gA REF_EXTENSIONS=()
    declare -ga EXCLUDE_EXT_ALL=()

    while IFS= read -r line; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "$stripped" == core:* ]]; then
            REF_CORE="${stripped#core:}"
            REF_CORE="${REF_CORE// /}"
            section=""
        elif [[ "$stripped" == "extensions:" ]]; then
            section="extensions"
        elif [[ "$stripped" == "exclude-ext-all:" ]]; then
            section="exclude-ext-all"
        elif [[ "$section" == "extensions" ]] && [[ "$stripped" == *:* ]] && [[ "$stripped" != "#"* ]]; then
            local name="${stripped%%:*}"
            local version="${stripped#*:}"
            name="${name// /}"
            version="${version// /}"
            if [[ -n "$name" && -n "$version" ]]; then
                REF_EXTENSIONS["$name"]="$version"
            fi
        elif [[ "$section" == "exclude-ext-all" ]] && [[ "$stripped" == "- "* ]]; then
            local val="${stripped#- }"
            val="${val// /}"
            EXCLUDE_EXT_ALL+=("$val")
        elif [[ "$stripped" != "" && "$stripped" != "#"* && "$stripped" != "reference:" ]]; then
            section=""
        fi
    done < "$VERSIONS_FILE"

    if [[ -n "$CORE_OVERRIDE" ]]; then
        REF_CORE="$CORE_OVERRIDE"
    fi
    for override in "${EXT_OVERRIDES[@]+"${EXT_OVERRIDES[@]}"}"; do
        local name="${override%%==*}"
        local version="${override#*==}"
        REF_EXTENSIONS["$name"]="$version"
    done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
download_manager() {
    mkdir -p "$TMP_BASE"
    if [[ ! -f "$MANAGER_PATH" ]]; then
        echo "Downloading h2c-manager from main..."
        curl -fsSL "$MANAGER_URL" -o "$MANAGER_PATH"
    fi
}

# Install h2c-core + extensions from main branch (no API calls)
# $1 = workdir
# $2+ = extension names (bare, no version pins)
install_from_main() {
    local workdir="$1"; shift
    local exts=("$@")

    mkdir -p "$workdir/.h2c/extensions"
    if [[ -n "$LOCAL_CORE" ]]; then
        cp "$LOCAL_CORE" "$workdir/.h2c/helmfile2compose.py"
    else
        curl -fsSL "$RAW_BASE/helmfile2compose/h2c-core/main/helmfile2compose.py" \
            -o "$workdir/.h2c/helmfile2compose.py"
    fi

    if [[ ${#exts[@]} -gt 0 ]]; then
        # Fetch registry once to resolve repo/file for each extension
        local registry
        registry=$(curl -fsSL "$REGISTRY_URL")
        for ext in "${exts[@]}"; do
            local repo file
            repo=$(printf '%s' "$registry" | python3 -c "import json,sys; print(json.load(sys.stdin)['extensions']['$ext']['repo'])")
            file=$(printf '%s' "$registry" | python3 -c "import json,sys; print(json.load(sys.stdin)['extensions']['$ext']['file'])")
            curl -fsSL "$RAW_BASE/$repo/main/$file" \
                -o "$workdir/.h2c/extensions/$file"
        done
    fi
}

write_h2c_yaml() {
    local dir="$1"; shift
    local core_ver="$1"; shift
    local exts=("$@")

    mkdir -p "$dir"
    {
        echo "helmfile2ComposeVersion: v1"
        echo "name: h2c-testsuite"
        if [[ -n "$core_ver" ]]; then
            echo "core_version: $core_ver"
        fi
        if [[ ${#exts[@]} -gt 0 ]]; then
            echo "depends:"
            for ext in "${exts[@]}"; do
                echo "  - $ext"
            done
        fi
    } > "$dir/helmfile2compose.yaml"
}

# Run h2c via h2c-manager (downloads pinned versions)
run_h2c() {
    local workdir="$1"
    local from_dir="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"
    (
        cd "$workdir"
        python3 "$MANAGER_PATH" run --from-dir "$from_dir" --output-dir "$output_dir"
    )
}

# Run h2c with pre-installed .h2c/ (no downloads)
run_h2c_local() {
    local workdir="$1"
    local from_dir="$2"
    local output_dir="$3"

    mkdir -p "$output_dir"
    (
        cd "$workdir"
        python3 "$MANAGER_PATH" --no-reinstall run --from-dir "$from_dir" --output-dir "$output_dir"
    )
}

diff_outputs() {
    local dir_a="$1"
    local dir_b="$2"
    local label="$3"
    local diff_file="$4"

    rm -f "$dir_a/helmfile2compose.yaml" "$dir_b/helmfile2compose.yaml"

    if diff -ru "$dir_a" "$dir_b" > "$diff_file" 2>&1; then
        echo "  $label: identical"
        return 0
    else
        local added removed changed
        added=$(grep -c '^+[^+]' "$diff_file" 2>/dev/null || true)
        removed=$(grep -c '^-[^-]' "$diff_file" 2>/dev/null || true)
        changed=$(grep -c '^diff ' "$diff_file" 2>/dev/null || true)
        echo "  $label: ${changed} file(s) differ (+${added} -${removed} lines)"
        cat "$diff_file"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Performance mode (uses core directly, no h2c-manager)
# ---------------------------------------------------------------------------
download_core() {
    local dest="$1"
    local version="$2"  # tag or "main"

    if [[ "$version" == "main" && -n "$LOCAL_CORE" ]]; then
        cp "$LOCAL_CORE" "$dest"
    elif [[ "$version" == "main" ]]; then
        curl -fsSL "$RAW_BASE/helmfile2compose/h2c-core/main/helmfile2compose.py" -o "$dest"
    else
        curl -fsSL "$RAW_BASE/helmfile2compose/h2c-core/refs/tags/$version/helmfile2compose.py" -o "$dest"
    fi
}

run_perf() {
    local n="$PERF_N"
    local torture_dir="/tmp/h2c-torture-${n}"

    echo "=== Performance test (n=$n) ==="
    echo ""

    python3 "$SCRIPT_DIR/generate.py" "$n" --output "$torture_dir/manifests"
    _CLEANUP_DIRS+=("$torture_dir")

    run_perf_single() {
        local label="$1"
        local version="$2"
        local core_path="$torture_dir/core-${label}.py"
        local output_dir="$torture_dir/output-${label}"

        download_core "$core_path" "$version"
        mkdir -p "$output_dir"

        echo "Running h2c ($label, $version)..."
        local start end elapsed
        start=$(python3 -c "import time; print(time.time())")
        python3 "$core_path" --from-dir "$torture_dir/manifests" --output-dir "$output_dir" 2>&1
        end=$(python3 -c "import time; print(time.time())")
        elapsed=$(python3 -c "print(f'{$end - $start:.2f}')")

        local compose_size services
        if [[ -f "$output_dir/compose.yml" ]]; then
            compose_size=$(wc -c < "$output_dir/compose.yml" | tr -d ' ')
            services=$(grep -c '^  [a-zA-Z]' "$output_dir/compose.yml" 2>/dev/null || echo "?")
        else
            compose_size="N/A"
            services="N/A"
        fi

        echo ""
        echo "Results ($label):"
        echo "  Wall time:  ${elapsed}s"
        echo "  Compose:    ${compose_size} bytes"
        echo "  Services:   ~${services}"
    }

    if [[ -n "$CORE_OVERRIDE" ]]; then
        run_perf_single "ref" "$CORE_OVERRIDE"
        echo ""
        run_perf_single "latest" "main"
    else
        run_perf_single "latest" "main"
    fi

    if $KEEP; then
        _CLEANUP_DIRS=("${_CLEANUP_DIRS[@]/$torture_dir}")
        echo ""
        echo "Keeping $torture_dir (--keep)"
    fi
}

# ---------------------------------------------------------------------------
# Regression mode
# ---------------------------------------------------------------------------
run_regression() {
    echo "=== Regression test (ref vs latest) ==="
    echo ""

    parse_versions_file

    echo "Reference: core=$REF_CORE"
    for ext in "${!REF_EXTENSIONS[@]}"; do
        echo "  $ext=${REF_EXTENSIONS[$ext]}"
    done
    echo ""

    download_manager
    _CLEANUP_DIRS+=("$TMP_BASE" "$TMP_BASE-ref" "$TMP_BASE-latest")

    local ext_names=()
    for ext in "${!REF_EXTENSIONS[@]}"; do
        ext_names+=("$ext")
    done
    mapfile -t ext_names < <(printf '%s\n' "${ext_names[@]}" | sort)

    # Build combo list
    declare -a COMBO_NAMES=()
    declare -a COMBO_REF_EXTS=()
    declare -a COMBO_LATEST_EXTS=()

    COMBO_NAMES+=("core-only")
    COMBO_REF_EXTS+=("")
    COMBO_LATEST_EXTS+=("")

    for ext in "${ext_names[@]}"; do
        COMBO_NAMES+=("ext-${ext}")
        COMBO_REF_EXTS+=("${ext}==${REF_EXTENSIONS[$ext]}")
        COMBO_LATEST_EXTS+=("${ext}")
    done

    # Build ext-all combo, excluding extensions listed in exclude-ext-all
    local all_ext_names=()
    for ext in "${ext_names[@]}"; do
        local excluded=false
        for ex in "${EXCLUDE_EXT_ALL[@]+"${EXCLUDE_EXT_ALL[@]}"}"; do
            if [[ "$ext" == "$ex" ]]; then excluded=true; break; fi
        done
        if ! $excluded; then all_ext_names+=("$ext"); fi
    done

    if [[ ${#all_ext_names[@]} -gt 1 ]]; then
        local ref_all="" latest_all=""
        for ext in "${all_ext_names[@]}"; do
            ref_all="${ref_all:+${ref_all}|}${ext}==${REF_EXTENSIONS[$ext]}"
            latest_all="${latest_all:+${latest_all}|}${ext}"
        done
        COMBO_NAMES+=("ext-all")
        COMBO_REF_EXTS+=("$ref_all")
        COMBO_LATEST_EXTS+=("$latest_all")
    fi

    local has_diff=false
    local diff_dir="$TMP_BASE/diffs"
    mkdir -p "$diff_dir"

    for i in "${!COMBO_NAMES[@]}"; do
        local combo="${COMBO_NAMES[$i]}"
        local ref_exts_str="${COMBO_REF_EXTS[$i]}"
        local latest_exts_str="${COMBO_LATEST_EXTS[$i]}"

        local ref_ext_args=() latest_ext_args=()
        if [[ -n "$ref_exts_str" ]]; then
            IFS='|' read -ra ref_ext_args <<< "$ref_exts_str"
        fi
        if [[ -n "$latest_exts_str" ]]; then
            IFS='|' read -ra latest_ext_args <<< "$latest_exts_str"
        fi

        # Ref: pinned versions via h2c-manager
        local ref_workdir="$TMP_BASE-ref/$combo"
        local ref_output="$ref_workdir/output"
        write_h2c_yaml "$ref_workdir" "$REF_CORE" "${ref_ext_args[@]+"${ref_ext_args[@]}"}"

        # Latest: install from main branches
        local latest_workdir="$TMP_BASE-latest/$combo"
        local latest_output="$latest_workdir/output"
        write_h2c_yaml "$latest_workdir" "" "${latest_ext_args[@]+"${latest_ext_args[@]}"}"
        install_from_main "$latest_workdir" "${latest_ext_args[@]+"${latest_ext_args[@]}"}"

        if ! run_h2c "$ref_workdir" "$MANIFESTS_DIR" "$ref_output" 2>&1; then
            echo "  $combo: ref run FAILED"
            has_diff=true
            continue
        fi

        if ! run_h2c_local "$latest_workdir" "$MANIFESTS_DIR" "$latest_output" 2>&1; then
            echo "  $combo: latest run FAILED"
            has_diff=true
            continue
        fi

        if ! diff_outputs "$ref_output" "$latest_output" "$combo" "$diff_dir/diff-${combo}.patch"; then
            has_diff=true
        fi
    done

    echo ""
    if $has_diff; then
        echo "RESULT: differences found (diffs in $diff_dir/)"
        exit 1
    else
        echo "RESULT: all combos identical (ref=$REF_CORE vs latest=main)"
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ -n "$PERF_N" ]]; then
    run_perf
else
    run_regression
fi
