#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_home developer-state
}

teardown() {
    mole_test_teardown_home
}

probe_developer_state() {
    local family="$1"
    local boundary="$2"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 MO_NO_OPLOG=1 FAMILY="$family" BOUNDARY="$boundary" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
case "$FAMILY" in
    wal)
        targets=("$HOME/.prometheus/data/wal/00000000")
        positive="$HOME/.grafana/cache/rebuildable"
        cleanup=clean_dev_cicd
        ;;
    backup)
        targets=("$HOME/.gitconfig.bak" "$HOME/.config/fish/fish_history.bak" "$HOME/.bash_history.bak" "$HOME/.zsh_history.bak")
        positive="$HOME/.oh-my-zsh/cache/rebuildable"
        cleanup=clean_dev_shell
        ;;
    lock)
        targets=("$HOME/.gitconfig.lock")
        positive="$HOME/.oh-my-zsh/cache/rebuildable"
        cleanup=clean_dev_shell
        ;;
    jupyter)
        targets=("$HOME/.jupyter/runtime/kernel-fixture.json")
        positive="$HOME/.pyenv/cache/rebuildable"
        cleanup=clean_dev_python
        pip3() { return 1; }
        uv() { return 1; }
        conda() { return 1; }
        run_with_timeout() { shift; "$@"; }
        ;;
esac
for target in "${targets[@]}" "$positive"; do
    mkdir -p "$(dirname "$target")"
    printf 'synthetic user state\n' > "$target"
done
# A freshly created file can still be an active WAL or config transaction.
exec 7>>"${targets[0]}"
trace="$HOME/sink-trace"
export trace
: > "$trace"
rm() { printf '%s\n' "${@: -1}" >> "$trace"; }
if [[ "$BOUNDARY" == candidate ]]; then
    # Inspect the producer independently from its protection backstop. The
    # neighboring cache is a positive control that the real producer ran.
    safe_clean() {
        local path
        for path in "${@:1:$#-1}"; do
            [[ ! -e "$path" ]] || printf '%s\n' "$path" >> "$trace"
        done
        return 0
    }
    "$cleanup"
else
    for target in "${targets[@]}" "$positive"; do
        safe_remove "$target" true || true
    done
fi
grep -Fx -- "$positive" "$trace" >/dev/null || exit 1
for target in "${targets[@]}"; do
    if grep -Fx -- "$target" "$trace" >/dev/null; then
        printf 'UNSAFE:%s\n' "${target#"$HOME"/}"
        exit 1
    fi
    [[ -f "$target" ]] || exit 1
done
if [[ "$BOUNDARY" == sink ]]; then
    # Protection belongs to automated cleanup, not explicit uninstall choices.
    for target in "${targets[@]}"; do
        if MOLE_UNINSTALL_MODE=1 should_protect_path "$target"; then
            printf 'UNINSTALL_BLOCKED:%s\n' "$target"
            exit 1
        fi
    done
    if [[ "$FAMILY" == wal ]]; then
        should_protect_path "$HOME/.prometheus/data" || exit 1
    fi
    if [[ "$FAMILY" == jupyter ]]; then
        should_protect_path "$HOME/.jupyter/runtime" || exit 1
    fi
fi
printf 'SAFE:%s:%s\n' "$FAMILY" "$BOUNDARY"
EOF
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE:$family:$boundary"* ]] || return 1
}

@test "developer cleanup never nominates Prometheus recovery WAL" {
    probe_developer_state wal candidate
}

@test "developer cleanup never nominates sole config or shell-history backups" {
    probe_developer_state backup candidate
}

@test "developer cleanup never nominates an active Git config lock" {
    probe_developer_state lock candidate
}

@test "cleanup sink protects Prometheus data while keeping ordinary caches cleanable" {
    probe_developer_state wal sink
}

@test "cleanup sink protects config and shell-history backups without blocking uninstall" {
    probe_developer_state backup sink
}

@test "cleanup sink protects an open Git config lock without blocking uninstall" {
    probe_developer_state lock sink
}

@test "developer cleanup never nominates Jupyter runtime connection files" {
    probe_developer_state jupyter candidate
}

@test "cleanup sink protects Jupyter runtime without blocking uninstall" {
    probe_developer_state jupyter sink
}

@test "npm cleanup preserves runtime resources in default and custom npx stores" {
    command -v node >/dev/null 2>&1 || skip "node is required for the running package fixture"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" NODE_BIN="$(command -v node)" \
        MOLE_TEST_NO_AUTH=1 python3 -I <<'PY'
import os
from pathlib import Path
import select
import subprocess

home = Path(os.environ['HOME'])
roots = [home / '.npm', home / 'custom npm cache']
packages = []
for root in roots:
    package = root / '_npx/fixture/node_modules/fixture'
    package.mkdir(parents=True)
    (package / 'resource.txt').write_text('RESOURCE_OK')
    (package / 'lazy.cjs').write_text("module.exports = 'MODULE_OK'")
    packages.append(str(package))
    for directory in ['_cacache', '_logs', '_prebuilds']:
        target = root / directory
        target.mkdir()
        (target / 'disposable').write_text('cache')

fake_bin = home / 'bin'
fake_bin.mkdir()
(fake_bin / 'npm').write_text('''#!/bin/bash
[[ "$*" == "config get cache" ]] && printf '%s\\n' "$HOME/custom npm cache"
exit 0
''')
(fake_bin / 'npm').chmod(0o755)

worker = home / 'worker.cjs'
worker.write_text('''
const fs = require('node:fs');
const roots = process.argv.slice(2);
setTimeout(() => process.exit(2), 60000).unref();
require('node:readline').createInterface({input: process.stdin}).on('line', cmd => {
    try {
        console.log(roots.map(root => cmd === 'module' ? require(root + '/lazy.cjs') :
            fs.readFileSync(root + '/resource.txt', 'utf8')).join(','));
    } catch (error) { console.log(error.code); }
});
''')
child = subprocess.Popen([os.environ['NODE_BIN'], str(worker), *packages],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
try:
    def request(command):
        child.stdin.write((command + '\n').encode())
        child.stdin.flush()
        assert select.select([child.stdout], [], [], 10)[0], 'response timeout'
        return child.stdout.readline().decode().strip()

    assert request('resource') == 'RESOURCE_OK,RESOURCE_OK'
    # Only npm's external command is stubbed; the cleanup and deletion guards
    # are real. The sibling caches prove the deletion path was exercised.
    cleanup = '''
source "$PROJECT_ROOT/bin/clean.sh"
clean_pnpm_stores() { :; }
clean_corepack_cache() { :; }
clean_dev_npm
'''
    for dry_run in ['1', '0']:
        result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', cleanup],
                                env={**os.environ, 'PATH': f'{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                                     'MOLE_DRY_RUN': dry_run},
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'npx' not in result.stdout, result.stdout
        assert request('resource') == 'RESOURCE_OK,RESOURCE_OK'
        for root in roots:
            for directory in ['_cacache', '_logs', '_prebuilds']:
                assert (root / directory / 'disposable').exists() == (dry_run == '1')
    assert request('module') == 'MODULE_OK,MODULE_OK'
    print('Runtime resources and lazy modules remain usable; sibling caches are cleaned')
finally:
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}
