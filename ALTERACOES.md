# Alterações locais (branch `camera-livre-multiplayer`)

Este arquivo resume o que foi alterado em relação ao `main` do projeto original (commit `9cfebde`, versão 1.4.7).
Ele também diz em que ponto o trabalho parou, para dar para continuar em outro PC.

Há duas frentes:

1. **Câmera livre no multiplayer.** O código está pronto, mas ainda não foi testado no jogo.
2. **Compilar direto no Steam Deck**, sem o pacote tar nem o launcher. A compilação passa, mas a ligação final ainda falhava na última tentativa.

---

## 1. Câmera livre por controle no multiplayer

### O problema

No modo de 2 jogadores (testado no Linux/Steam Deck), o direcional direito do jogador 2 girava a câmera do jogador 1.

A causa:

- A câmera livre lia o direcional direito pelo `recompinput` como "controle 0".
- No modo de um jogador, o `recompinput` junta nesse controle 0 a entrada de **todos** os controles.
- Além disso, só existia uma órbita de câmera, sempre ligada à câmera em jogo (`D_800DBFF0`).

A câmera livre não pode simplesmente ser desligada no multiplayer, porque ela faz parte do projeto. Por isso a correção dá a cada jogador a sua própria câmera livre.

### A solução

**[host/src/free_camera.cpp](host/src/free_camera.cpp)**

- Agora há uma órbita por jogador: `Orbit orbits[4]`. Antes era uma única `orbit`.
  - O estado do clique do direcional (zoom) e o relógio do direcional também passaram a ser de cada órbita. Antes eram `static` globais.
- `camera_player()` lê o índice do jogador em `+0x23D` da câmera, igual ao `camera_player` do `look_aim.cpp`.
- `orbit_for()` devolve a órbita certa para cada câmera.
  - Para o jogador 1, a câmera ainda precisa ser a câmera em jogo (`D_800DBFF0`), como antes.
- `player_controller()` descobre qual controle SDL é de cada jogador:
  - No modo de um jogador do recompinput, pelas portas do `conker::frontend::port_controllers` (`frontend.cpp`).
  - No modo multiplayer do recompinput, pelos jogadores que ele atribuiu.
  - Se só o jogador 1 tem porta, o comportamento antigo continua: o direcional de qualquer controle.
- `conker::player_right_stick(player, …)` lê o direcional direito do controle desse jogador. É uma função nova.
- `conker::free_camera_stick(player, …)` ganhou o parâmetro `player`.
- O mouse e a roda do mouse giram só a câmera do jogador 1.
- Algumas opções continuam só do jogador 1:
  - "Camera: Field of View";
  - "Aiming: Face Where the Camera Looks";
  - a orientação da mira.
- O cálculo da inclinação do chão usa o personagem que a câmera segue:
  - Conker (`player_object`) para o jogador 1;
  - `+0x3D0` da câmera para os outros jogadores.
- O modo de mirar (segurar R) agora é marcado por câmera:
  - O gancho `conker_mouse_camera_look_mode` apenas marca `look_mode_unclaimed`.
  - Depois, `conker::free_camera_look_mode(rdram, camera)`, chamado pelo `look_aim.cpp`, diz de qual câmera ele é.
  - Se nenhum gancho disser, `settle_look_mode()` marca todas as câmeras, como era antes.

**[host/src/conker.hpp](host/src/conker.hpp)**: declarações novas.

- `free_camera_stick(int player, …)`
- `player_right_stick(int player, …)`
- `free_camera_look_mode(uint8_t*, uint64_t)`

**[host/src/frontend.cpp](host/src/frontend.cpp)**

- O bloqueio dos botões C enquanto o direcional direito está empurrado agora vale para cada controle (0 a 3), cada um com o seu próprio direcional.
- Antes valia só para o controle 0.

**[host/src/look_aim.cpp](host/src/look_aim.cpp)**

- `conker_look_targets` e `conker_look_currents` chamam `conker::free_camera_look_mode(rdram, ctx->r16)`, sendo `$s0` a câmera.

**[host/src/photo_mode.cpp](host/src/photo_mode.cpp)**

- O modo foto passou a ler o direcional direito do controle do jogador 1 (`player_right_stick(0, …)`).
- Antes lia o de todos os controles juntos.

### Para testar

1. Compile o projeto e abra um modo de 2 jogadores (multiplayer) com dois controles.
2. Mexa o direcional direito do controle 2. Só a câmera do jogador 2 deve girar.
3. Repita com o controle 1.
4. Clique o direcional direito (zoom) de cada controle. Cada clique deve mudar só a distância da própria câmera.
5. Segure R (mirar) com um jogador. A câmera livre desse jogador deve devolver a câmera ao jogo, e a do outro deve continuar livre.
6. No modo de um jogador, tudo deve continuar como antes, inclusive o mouse.

---

## 2. Compilar no Steam Deck: `tools/build_deck.sh`

Este script é novo. Ele faz tudo sem precisar digitar nada: basta abrir o arquivo pelo gerenciador de arquivos, e ele se reabre no Konsole.

Tudo é compilado dentro de um container distrobox (Ubuntu 24.04), chamado `conker-build`.

O passo a passo do script:

1. Instala as ferramentas (apt). Só acontece uma vez.
2. Gera a decompilação `mkst/conker` (commit `3adf229`) a partir da ROM, em `conker/`.
   - A ROM é a americana (`.z64`), com qualquer nome, nesta pasta ou na pasta acima.
3. Compila o N64Recomp (commit `ffb39cd`), em `N64Recomp/`.
4. Traduz o jogo (`recomp/out`).
   - Refaz quando `recomp/conker.toml` ou `recomp/prepare_elf.py` ficam mais novos que `recomp/out/recomp_overlays.inl`.
5. Baixa as dependências e compila o programa, em `build-linux/`.

Tudo o que aparece na tela também vai para `build-deck.log`. Para mudar quantos arquivos compilam ao mesmo tempo, use `JOBS=N` (o padrão é 4).

### Problemas já resolvidos no script

- **ROM não encontrada:** o script procura qualquer `.z64` na pasta do projeto ou na pasta acima.
- **A decompilação não monta** (`nonmatching`, `alabel`, `endlabel`, `enddlabel`, "text block without an initial glabel"):
  - O script acrescenta essas macros ao `macro.inc`.
  - Também adapta `asm/nonmatchings`, porque o splat/spimdisasm novo do pip gera um formato diferente.
- **Fins de linha do Windows (CRLF):** uma cópia feita do Windows quebra o bash e os patches. O script converte só os arquivos que ainda têm `\r`.
- **Caminho com espaço** (`PC RECOMPS`): o `dxc` do RT64 quebra com espaço no caminho.
  - A solução é compilar através do link `~/.conker-build-src`, que aponta para a pasta do projeto.
- **`setup_deps.sh` falha na segunda vez** (`rt64.patch` não aplica mais):
  - O script aplica os patches uma vez e marca com `deps/.deck_deps_ok`.
  - Para refazer tudo, apague a pasta `deps/`.

### `recomp/prepare_elf.py`: funções internas da libultra

O spimdisasm novo, instalado pelo pip, **dá nome** a funções internas da libultra que antes ficavam como `func_XXXXXXXX`.

Esses nomes estão na lista `ignored_funcs` do N64Recomp. O resultado é o seguinte:

- O N64Recomp não traduz essas funções.
- O runtime também não oferece a versão `<nome>_recomp` delas.
- Mas o código do jogo continua chamando essas funções.
- Então a ligação final falha com `undefined reference to <nome>_recomp`.

A correção está no conjunto `UNPROVIDED_IGNORED` (por volta da linha 412). O script troca esses nomes de volta para `func_<vram>`, e aí elas são traduzidas junto com o resto do jogo.

Só entram na lista nomes que deram erro de verdade, ou funções irmãs do mesmo código:

- **Rumble:** `_MakeMotorData`
- **SI/controle:**
  - `__osPackRequestData`, `__osContGetInitData`
  - `__osSiRawStartDma`, `__osSiCreateAccessQueue`, `__osSiDeviceBusy`, `__osSiGetAccess`, `__osSiRelAccess`
- **Timer:** `__osInsertTimer`, `__osSetTimerIntr`, `__osSetCompare`
- **Controller Pak:**
  - `__osContRamWrite`, `__osContRamRead`
  - `__osPackRamReadData`, `__osPackRamWriteData`
  - `__osContDataCrc`, `__osContAddressCrc`
  - `__osPfsGetStatus`, `__osPfsSelectBank`, `__osPfsGetInitData`, `__osPfsRWInode`
  - `__osPackReadData`, `__osIdCheckSum`, `__osRepairPackId`, `__osCheckPackId`, `__osGetId`, `__osCheckId`

Não acrescente nomes "por garantia" fora dessas famílias. Se o runtime oferecer uma dessas funções e ela for renomeada, a versão do runtime deixa de ser usada e o comportamento muda.

---

## Onde paramos

- **Último log** (`build-deck (8)`): tudo compila, mas a ligação final falha.
  - Os nomes que faltavam eram `__osPackRamReadData`, `__osPackRamWriteData`, `__osContDataCrc` e `__osPfsGetStatus`.
- Esses nomes, mais as funções irmãs do Controller Pak, **já foram acrescentados**.
- Essa versão ainda **não foi testada no Deck**.

### Próximos passos

1. Copie o `recomp/prepare_elf.py` para o Deck e rode o `tools/build_deck.sh`.
   - O script refaz a tradução sozinho (uns 4 minutos) e recompila os cerca de 120 arquivos do jogo.
2. Se ainda aparecer `undefined reference to <nome>_recomp`, acrescente o nome a `UNPROVIDED_IGNORED` e rode de novo.
3. Quando a ligação passar, siga os testes da seção 1.
