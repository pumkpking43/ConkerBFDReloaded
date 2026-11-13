#!/usr/bin/env bash
# Steam Deck (desktop mode): builds ConkerBFDReloaded from this folder with no typing. Open it from the file
# manager (it reopens itself in Konsole) or run it in a terminal. Everything is built inside a distrobox container
# (Ubuntu 24.04), as SteamOS itself is read-only:
#   1. the build tools (apt), once;
#   2. the mkst/conker decompilation (commit 3adf229) from the ROM, into conker/, once;
#   3. N64Recomp (commit ffb39cd, with patches/n64recomp*.patch), into N64Recomp/, once;
#   4. the game's translation (tools/prepare_game.sh, N64Recomp), into recomp/out, again when recomp/conker.toml changes;
#   5. the dependencies (tools/setup_deps.sh) and the program (tools/build_linux.sh), into build-linux/.
# Each step that's done is skipped the next time, so after a change to host/src only step 5 runs again.
# The ROM: the US Conker's Bad Fur Day (.z64), in this folder (any name) or the folder above it.
# Everything it prints also goes to build-deck.log here. JOBS=N sets how many files compile at once (default 4).
#   tools/build_deck.sh
set -euo pipefail

SELF=$(readlink -f "$0")
R=$(cd "$(dirname "$SELF")/.." && pwd)
BOX=conker-build
JOBS=${JOBS:-4}

# Opened from the file manager (no terminal): reopen in Konsole, kept open at the end to read it.
if [ ! -t 1 ] && [ -z "${CONKER_IN_TERMINAL:-}" ] && command -v konsole >/dev/null 2>&1; then
    export CONKER_IN_TERMINAL=1
    exec konsole --hold -e bash "$SELF" "$@"
fi
export CONKER_IN_TERMINAL=1

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mERRO: %s\033[0m\nVeja o log completo em: %s\n' "$*" "$R/build-deck.log"; exit 1; }
step=""
trap 'printf "\n\033[1;31mERRO na etapa: %s\033[0m\nVeja o log completo em: %s\n" "$step" "$R/build-deck.log"' ERR

in_container() { [ -f /run/.containerenv ] || [ -n "${CONTAINER_ID:-}" ]; }

# ---------------------------------------------------------------- on SteamOS: the container
if ! in_container; then
    exec > >(tee -a "$R/build-deck.log") 2>&1
    echo "---- $(date) ----"
    say "Projeto: $R"
    command -v distrobox >/dev/null 2>&1 || fail "distrobox não encontrado (SteamOS 3.5 ou mais novo já vem com ele)."
    step="criar o container $BOX"
    if ! distrobox list 2>/dev/null | grep -qw "$BOX"; then
        say "Criando o container $BOX (Ubuntu 24.04): baixa uns 100 MB, só na primeira vez"
        distrobox create --yes --name "$BOX" --image docker.io/library/ubuntu:24.04
    fi
    step="compilar dentro do container"
    say "Entrando no container (a primeira entrada demora alguns minutos)"
    distrobox enter "$BOX" -- env CONKER_IN_TERMINAL=1 CONKER_LOGGING=1 JOBS="$JOBS" bash "$SELF"

    # The program runs on SteamOS itself: any library it needs that SteamOS lacks?
    step="conferir as bibliotecas"
    missing=$(ldd "$R/build-linux/ConkerBFDReloaded" 2>/dev/null | grep "not found" || true)
    if [ -n "$missing" ]; then
        printf '\n\033[1;33mAviso: faltam bibliotecas no SteamOS para rodar fora do container:\033[0m\n%s\n' "$missing"
        echo "Dá para rodar de dentro do container: distrobox enter $BOX -- \"$R/build-linux/ConkerBFDReloaded\""
    fi
    say "PRONTO: $R/build-linux/ConkerBFDReloaded"
    echo "Para o modo jogo: no gerenciador de arquivos, clique com o botão direito nele > Add to Steam."
    exit 0
fi

# ---------------------------------------------------------------- inside the container
if [ -z "${CONKER_LOGGING:-}" ]; then
    exec > >(tee -a "$R/build-deck.log") 2>&1
fi
cd "$R"

# A copy from Windows (git's autocrlf) leaves the project's files with CRLF line endings, which bash, the
# patches and the tools here don't take ("set: -: invalid option", "$'...\r'"). Only files that still
# have a CR are rewritten, so the ones already converted keep their dates (and don't rebuild again).
step="converter os fins de linha (CRLF) para Linux"
crlf=$(find "$R/tools" "$R/recomp" "$R/patches" "$R/host" -maxdepth 4 -type f \
    \( -name '*.sh' -o -name '*.py' -o -name '*.toml' -o -name '*.patch' -o -name '*.txt' -o -name '*.cmake' \
       -o -name '*.h' -o -name '*.hpp' -o -name '*.c' -o -name '*.cpp' -o -name '*.inl' -o -name '*.ld' \
       -o -name '*.rml' -o -name '*.rcss' -o -name '*.json' \) \
    -not -path '*/out/*' -exec grep -lI $'\r' {} + 2>/dev/null || true)
if [ -n "$crlf" ]; then
    say "Convertendo fins de linha do Windows (CRLF) em $(printf '%s\n' "$crlf" | wc -l) arquivos"
    printf '%s\n' "$crlf" | while IFS= read -r f; do sed -i 's/\r$//' "$f"; done
fi

step="instalar as ferramentas (apt)"
if [ ! -f "$HOME/.conker-build-tools-ok" ] || ! command -v mips-linux-gnu-objcopy >/dev/null 2>&1; then
    say "Instalando as ferramentas de compilação (só na primeira vez)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential gcc-13 g++-13 cmake ninja-build pkg-config git ca-certificates less unzip wget \
        python3 python3-pip python3-venv python-is-python3 binutils-mips-linux-gnu libglib2.0-0 \
        libsdl2-dev libgtk-3-dev libfreetype-dev libx11-dev libvulkan-dev
    touch "$HOME/.conker-build-tools-ok"
fi
export CC=gcc-13 CXX=g++-13

step="achar a ROM"
if [ ! -f "$R/conker.z64" ]; then
    rom=$(find "$R" "$R/.." -maxdepth 1 -iname '*.z64' -type f 2>/dev/null | head -n 1 || true)
    [ -n "$rom" ] || fail "ROM não encontrada. Coloque a ROM americana (.z64) nesta pasta: $R"
    say "ROM: $rom"
    cp "$rom" "$R/conker.z64"
fi

# ---- the decompilation
E="$R/conker/conker/build/conker.us.elf"
step="compilar a decompilação (mkst/conker)"
if [ ! -f "$E" ]; then
    say "Decompilação: baixando mkst/conker"
    [ -d "$R/conker/.git" ] || git clone https://github.com/mkst/conker.git "$R/conker"
    git -C "$R/conker" checkout -q 3adf229
    git -C "$R/conker" submodule update --init --recursive
    cp "$R/conker.z64" "$R/conker/baserom.us.z64"
    say "Decompilação: instalando os pacotes Python"
    [ -d "$R/conker/.venv" ] || python3 -m venv "$R/conker/.venv"
    # shellcheck disable=SC1091
    . "$R/conker/.venv/bin/activate"
    pip install -q -r "$R/conker/requirements.txt"
    [ ! -f "$R/conker/tools/n64splat/requirements.txt" ] || pip install -q -r "$R/conker/tools/n64splat/requirements.txt"
    say "Decompilação: conferindo a ROM"
    make -C "$R/conker" check || fail "a ROM não é a americana esperada (conker.us.sha1). Use a ROM US em .z64."
    say "Decompilação: extraindo e compilando (demora)"
    make -C "$R/conker" extract
    make -C "$R/conker/conker" extract
    # The disassembler pip installs now (spimdisasm, newer than this decompilation) writes macros its
    # include/macro.inc doesn't have (nonmatching first: "unrecognized opcode `nonmatching ...'"). The ones
    # missing are added there, as newer splat projects define them; they only mark labels.
    step="completar as macros do assembly (macro.inc)"
    M="$R/conker/conker/include/macro.inc"
    [ -f "$M" ] || M=$(find "$R/conker/conker" -name macro.inc -path '*include*' | head -n 1)
    [ -n "$M" ] && [ -f "$M" ] || fail "não achei o include/macro.inc da decompilação"
    add_macro() { # name, definition
        if ! grep -Eq "^[[:space:]]*\.macro[[:space:]]+$1([[:space:],]|$)" "$M"; then
            printf '\n%b\n' "$2" >> "$M"
            echo "  macro.inc: $1 adicionada"
        fi
    }
    add_macro nonmatching '.macro nonmatching label, size=1\n.endm'
    add_macro glabel '.macro glabel label\n    .global \\label\n    .type \\label, @function\n    \\label:\n.endm'
    add_macro dlabel '.macro dlabel label\n    .global \\label\n    \\label:\n.endm'
    add_macro jlabel '.macro jlabel label\n    \\label:\n.endm'
    add_macro alabel '.macro alabel label\n    .global \\label\n    \\label:\n.endm'
    add_macro endlabel '.macro endlabel label\n.endm'
    add_macro enddlabel '.macro enddlabel label\n.endm'
    # The functions still in assembly inside C files (asm/nonmatchings, read by the decompilation's older
    # asm-processor) must start with glabel and have only labels and instructions: the newer marks
    # (nonmatching, endlabel, enddlabel) are taken out, and dlabel/alabel/jlabel made the old glabel and
    # plain labels ("Error: .text block without an initial glabel").
    step="adaptar o assembly para o asm-processor"
    N="$R/conker/conker/asm/nonmatchings"
    if [ -d "$N" ]; then
        find "$N" -name '*.s' -exec sed -i -E \
            -e '/^[[:space:]]*(nonmatching|endlabel|enddlabel)([[:space:]]|$)/d' \
            -e 's/^([[:space:]]*)(dlabel|alabel)([[:space:]])/\1glabel\3/' \
            -e 's/^([[:space:]]*)jlabel[[:space:]]+([^[:space:]]+)[[:space:]]*$/\1\2:/' {} +
        echo "  asm/nonmatchings: adaptado"
    fi
    step="compilar a decompilação (mkst/conker)"
    make -C "$R/conker/conker" --jobs "$JOBS"
    deactivate
    [ -f "$E" ] || fail "a decompilação terminou sem gerar $E"
fi

# ---- N64Recomp
step="compilar o N64Recomp"
if [ ! -x "$R/N64Recomp/build/N64Recomp" ] || [ ! -x "$R/N64Recomp/build/RSPRecomp" ]; then
    say "N64Recomp: baixando e compilando"
    [ -d "$R/N64Recomp/.git" ] || git clone https://github.com/N64Recomp/N64Recomp.git "$R/N64Recomp"
    git -C "$R/N64Recomp" checkout -q ffb39cd
    git -C "$R/N64Recomp" submodule update --init --recursive
    for p in n64recomp.patch n64recomp_conker.patch; do
        if ! git -C "$R/N64Recomp" apply --reverse --check --ignore-whitespace "$R/patches/$p" >/dev/null 2>&1; then
            git -C "$R/N64Recomp" apply --ignore-whitespace "$R/patches/$p"
        fi
    done
    cmake -S "$R/N64Recomp" -B "$R/N64Recomp/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    ninja -C "$R/N64Recomp/build" -j "$JOBS" N64Recomp RSPRecomp
fi

# ---- the translation (as tools/rebuild_all.sh does, without its copy to Windows)
step="traduzir o jogo (N64Recomp)"
O="$R/recomp/out"
if [ ! -f "$O/funcs.h" ] || [ ! -f "$O/segments.c" ] || [ "$R/recomp/conker.toml" -nt "$O/recomp_overlays.inl" ] \
   || [ "$R/recomp/prepare_elf.py" -nt "$O/recomp_overlays.inl" ]; then
    say "Traduzindo o código do jogo (demora alguns minutos)"
    bash "$R/tools/prepare_game.sh"
    cd "$R/recomp"
    rm -rf out_new && mkdir out_new
    sed 's#^output_func_path = "out"#output_func_path = "out_new"#' conker.toml > .translate.toml
    N64RECOMP_KEEP_GOING=1 "$R/N64Recomp/build/N64Recomp" .translate.toml > translate.log 2>&1 || { tail -n 20 translate.log; fail "a tradução falhou (recomp/translate.log)"; }
    rm -f .translate.toml
    cp -r out/rsp out_new/
    rm -rf out && mv out_new out
    python3 "$R/tools/emit_segments.py" "$R/recomp" out/segments.c
    cd "$R"
fi

# ---- the program
step="baixar as dependências (tools/setup_deps.sh)"
# setup_deps.sh can't tell rt64.patch is already in once the later rt64_*.patch files changed the same lines
# (its reverse check fails and so does applying it again), so a second run stops there. Patch once, mark it,
# and skip it after. A build-linux/ that cmake already configured means an earlier run got through this step.
# (Delete the deps/ folder to fetch and patch everything again.)
DEPS_OK="$R/deps/.deck_deps_ok"
if [ ! -f "$DEPS_OK" ] && [ -d "$R/deps/rt64/.git" ] && [ -f "$R/build-linux/CMakeCache.txt" ]; then
    touch "$DEPS_OK"
fi
if [ -f "$DEPS_OK" ]; then
    say "Dependências: já baixadas e corrigidas (pulando)"
else
    say "Dependências: runtime, RT64 e RecompFrontend"
    bash "$R/tools/setup_deps.sh"
    touch "$DEPS_OK"
fi

step="compilar o programa (tools/build_linux.sh)"
say "Compilando o ConkerBFDReloaded com $JOBS arquivos por vez (a primeira vez demora bastante: deixe o Deck na tomada)"
# RT64's shader step (dxc) breaks on a folder with a space in its path ("PC RECOMPS": "LD_LIBRARY_PATH=...:
# not found"), so the build goes through a link with no spaces to this folder, as tools/build_linux.sh
# does it. A build-linux/ configured with the old path is configured again (its CMake cache only).
L="$HOME/.conker-build-src"
ln -sfn "$R" "$L"
if [ -f "$R/build-linux/CMakeCache.txt" ] && ! grep -q "^CMAKE_HOME_DIRECTORY:INTERNAL=$L/host\$" "$R/build-linux/CMakeCache.txt"; then
    rm -rf "$R/build-linux/CMakeCache.txt" "$R/build-linux/CMakeFiles"
fi
cmake -S "$L/host" -B "$L/build-linux" -G Ninja -DCMAKE_BUILD_TYPE=Release -DDEPS_DIR="$L/deps" -DRECOMP_OUT="$L/recomp/out"
ninja -C "$L/build-linux" -j "$JOBS"
[ -f "$R/build-linux/ConkerBFDReloaded" ] || fail "a compilação terminou sem gerar build-linux/ConkerBFDReloaded"
