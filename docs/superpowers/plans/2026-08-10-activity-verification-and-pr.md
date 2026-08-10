# Проверка, документация и upstream PR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILLS: Use superpowers:requesting-code-review after implementation, superpowers:verification-before-completion before every success claim, and superpowers:finishing-a-development-branch for publication.

**Goal:** Доказать функциональную корректность, энергоэффективность и отсутствие новых permission/privacy regressions, задокументировать feature и подготовить принимаемый upstream pull request из fork.

**Architecture:** Автоматические gates выполняются локально и в GitHub Actions; hardware/UI behavior проверяется отдельной воспроизводимой manual matrix. Публичная история сохраняет небольшие тематические commits. Версия и release notes остаются в ответственности maintainer.

**Tech Stack:** SwiftPM/XCTest, existing bundle script, GitHub Actions macOS runner, Instruments/Activity Monitor, Git/GitHub.

## Запреты

- Не менять `Scripts/version`, не создавать tag/release и не добавлять `docs/releases/*`.
- Не force-push в upstream и не пушить напрямую в `akalikbergenov/cyclop`.
- Не заявлять browser/Яндекс Музыка compatibility без manual evidence.
- Не включать `.superpowers/`, local build artifacts, timers/download metadata или персональные пути в commit.
- Не открывать ready-for-review PR до полного green gate; draft допустим только после демонстрации работоспособного end-to-end slice.

---

### Task 0: Создать fork до начала production implementation

**Files:**
- Local git config only; repository files не меняются.

- [ ] **Step 1: Проверить identity/remotes/clean scope**

Run:

```bash
git remote -v
git status --short
git branch --show-current
```

Expected: `upstream` указывает на `akalikbergenov/cyclop`, branch `codex/activity-center`; кроме plan files допускается только untracked `.superpowers/`.

- [ ] **Step 2: Создать GitHub fork `mrvinil/cyclop`**

Через authenticated GitHub UI: нажать Fork для `akalikbergenov/cyclop`, owner `mrvinil`, repository name `cyclop`, copy only main=false допустимо, потому что feature branch отправится отдельно. Если к моменту исполнения установлен `gh`, эквивалент:

```bash
gh repo fork akalikbergenov/cyclop --clone=false --remote=false
```

Expected: `https://github.com/mrvinil/cyclop` открывается и показывает fork relationship.

- [ ] **Step 3: Добавить origin и защитить upstream от push**

```bash
git remote add origin https://github.com/mrvinil/cyclop.git
git remote set-url --push upstream DISABLED
git remote -v
```

Expected: fetch upstream остаётся official URL; push upstream=`DISABLED`; origin fetch/push указывает на fork.

- [ ] **Step 4: Закоммитить и запушить утверждённые plans в fork**

```bash
git add docs/superpowers/plans
git commit -m "docs: plan full activity system"
git push -u origin codex/activity-center
```

Expected: feature branch существует только в fork; `.superpowers/` не попала в commit.

- [ ] **Step 5: Зафиксировать upstream base**

```bash
git fetch upstream
git merge-base --is-ancestor upstream/main HEAD
git log --oneline --decorate upstream/main..HEAD
```

Expected: branch основана на текущем upstream/main; история содержит design/plan commits и последующие тематические commits.

### Task 1: Выбрать согласованный локальный toolchain до реализации

**Files:**
- Repository files не меняются.

- [ ] **Step 1: Собрать диагностику без изменений системы**

Run:

```bash
xcode-select -p
xcrun --show-sdk-path
swift --version
xcodebuild -version
swift build
```

Expected before implementation: полный Xcode/CLT и macOS SDK совместимы; `swift build` PASS.

- [ ] **Step 2: Использовать установленный Xcode 26.6 без глобального изменения системы**

В текущем окружении active `/Library/Developer/CommandLineTools` сочетает compiler Swift 6.3.3 с SDK 6.3.2 и не подходит. Установленный `/Applications/Xcode.app` согласован. Для agent commands использовать:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/cyclop-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/cyclop-swiftpm-module-cache \
swift build --disable-sandbox
```

`--disable-sandbox` отключает только внутренний sandbox SwiftPM; внешний workspace sandbox Codex остаётся активным. Baseline v0.6.4 этой командой уже собран успешно 2026-08-10.

- [ ] **Step 3: Только если Xcode действительно требует license, остановиться и попросить владельца Mac выполнить**

```bash
sudo xcodebuild -license accept
```

Эту команду выполняет пользователь осознанно в своём Terminal. Agent не принимает юридическое соглашение и не запрашивает пароль.

- [ ] **Step 4: Опционально предложить владельцу переключить default toolchain**

Если пользователь хочет убрать `DEVELOPER_DIR` из последующих shell-команд, он может сам выполнить `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. Это удобство, не блокер. Не подменять system SDK и не копировать `.swiftmodule` вручную.

- [ ] **Step 5: Записать baseline**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --disable-sandbox
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/bundle.sh debug
```

Expected: v0.6.4 base собирается до feature changes. Если baseline падает при согласованном toolchain, зафиксировать log и не приписывать failure новой feature.

### Task 2: Обновить CI под tests + bundle gate

**Files:**
- Modify: `.github/workflows/build.yml:1-58`

- [ ] **Step 1: Удалить устаревшее утверждение «тестов нет»**

Заменить header comment на описание двух честных gates: XCTest и release bundle/sign/localization.

- [ ] **Step 2: Добавить test step перед bundle**

```yaml
      - name: Тесты
        run: swift test --parallel

      - name: Сборка приложения
        run: ./Scripts/bundle.sh release
```

- [ ] **Step 3: Добавить metadata leak guard**

```yaml
      - name: В репозитории нет пользовательских данных активностей
        run: |
          test -z "$(git ls-files '*timers.json' '*downloads.json' '.superpowers/**')"
```

- [ ] **Step 4: Проверить workflow локально доступными командами**

Run:

```bash
swift test --parallel
./Scripts/bundle.sh release
codesign --verify --strict build/Cyclop.app
```

Expected: PASS.

- [ ] **Step 5: Закоммитить CI**

```bash
git add .github/workflows/build.yml
git commit -m "ci: test activity system before bundling"
```

### Task 3: Выполнить automated regression и failure-injection matrix

**Files:**
- Create: `docs/testing/activity-automated-gates.md`
- Tests may be modified only to close discovered gaps.

- [ ] **Step 1: Запустить clean test suite дважды**

```bash
swift package clean
swift test --parallel
swift test --parallel
```

Expected: оба запуска PASS; tests не зависят от порядка и не оставляют state в standard UserDefaults/Application Support.

- [ ] **Step 2: Запустить focused suites**

```bash
swift test --filter 'ActivityCoordinator|ActivityAttention|NotchPresentation|NotchLayout'
swift test --filter 'Timer'
swift test --filter 'Download'
swift test --filter 'Media|Meeting'
swift test --filter 'Privacy|Localization|Composition'
```

Expected: PASS каждого gate.

- [ ] **Step 3: Проверить corrupted storage**

Tests должны инъецировать invalid JSON, permission-denied save и destination move failure. Expected: source-level localized diagnostic, остальные sources работают, ни один файл пользователя не удалён автоматически.

- [ ] **Step 4: Проверить time jumps**

Fake clock matrix: +1s boundary, sleep через timer deadline, wake после meeting threshold/start/end, DST forward/back. Expected: абсолютные Date deadlines корректны; attention не дублируется; timer completion sound one-shot.

- [ ] **Step 5: Проверить download races**

Pause одновременно с finish; cancel queued; finish после cancel; duplicate delegate completion; watcher event до/после suppression; destination collision. Expected: deterministic final state, no overwrite, no duplicate attention.

- [ ] **Step 6: Документировать команды/результат и закоммитить**

В `activity-automated-gates.md` перечислить command, date, toolchain, result и известные skipped hardware checks; не вставлять домашний path.

```bash
git add docs/testing/activity-automated-gates.md Tests
git commit -m "test: harden activity failure handling"
```

### Task 4: Выполнить hardware/UI acceptance matrix

**Files:**
- Create: `docs/testing/activity-manual-matrix.md`

- [ ] **Step 1: Собрать и запустить debug app**

```bash
./Scripts/bundle.sh debug
open build/Cyclop.app
```

Expected: app запускается как accessory app; статус-иконка и idle notch работают.

- [ ] **Step 2: Проверить physical notch**

На MacBook Pro M1 Pro: idle, physical wings, compact, attention, expanded, active rect/click-through, auto/manual tab routing, Spaces, menu bar autohide, display sleep/wake. Снять screen recording без личных titles.

- [ ] **Step 3: Проверить synthetic notch**

На внешнем display или Mac без notch: synthetic capsule не блокирует соседние status items; pointer delay остаётся 0.3s; adaptive depths 16/32 pt ниже menu bar; клики вне active rect проходят приложению снизу.

- [ ] **Step 4: Проверить четыре sources end-to-end**

- Music: Apple Music, Spotify, browser, Яндекс Музыка согласно media matrix.
- Meetings: 5/10/15/30, one-minute/start, overlap, denied/no access, join.
- Timers: presets/custom, multiple, pause/resume/cancel, quit/relaunch, sleep/wake, sound off/on.
- Downloads: paste/drop URL, 3+ queue, pause/resume/retry/cancel, collision, unknown length, HTTP error, external Safari/Chrome completion, custom folder.

- [ ] **Step 5: Проверить privacy/accessibility/localization**

Russian and English app language; VoiceOver labels; Reduce Motion; activity privacy migration from old All state; masking in compact/attention/expanded; countdown/progress остаются видимыми.

- [ ] **Step 6: Заполнить matrix evidence**

Для каждой строки: environment, steps, expected, actual, PASS/FAIL, issue/commit. Любой FAIL возвращает к focused TDD task, затем весь affected gate повторяется.

- [ ] **Step 7: Закоммитить matrix**

```bash
git add docs/testing/activity-manual-matrix.md
git commit -m "test: record activity acceptance matrix"
```

### Task 5: Проверить энергоэффективность и ресурсы

**Files:**
- Create: `docs/testing/activity-energy-report.md`

- [ ] **Step 1: Снять baseline и feature idle**

Activity Monitor/Instruments Energy Log, release build, 10 минут each: v0.6.4 idle и feature idle. Записать average CPU, wakeups и memory. Expected: no recurring source timer in idle; regression должен быть объяснён и устранён до PR.

- [ ] **Step 2: Снять controlled scenarios**

10 минут: media playing compact slow mode; timer running compact; own download; expanded Activities. Проверить, что 1Hz появляется только для видимого countdown, media compact не тикает position, folder watcher событийный.

- [ ] **Step 3: Проверить animation modes**

Static/slow/fluid и Reduce Motion. Expected: static no periodic equalizer, slow <=1.25 wake/s from equalizer while visible, fluid <=4 wake/s while visible; hidden/paused zero.

- [ ] **Step 4: Проверить memory/task leaks**

50 open/close cycles, screen rebuild, source enable/disable, watcher folder changes. Expected: один composition, один folder descriptor, одна background session, subscriptions deallocated/constant.

- [ ] **Step 5: Записать результат и закоммитить**

```bash
git add docs/testing/activity-energy-report.md
git commit -m "perf: verify activity energy behavior"
```

### Task 6: Обновить пользовательскую и техническую документацию

**Files:**
- Modify: `README.md`
- Modify: `README.ru.md`
- Create: `docs/activities.md`

- [ ] **Step 1: Обновить feature table в двух README**

Добавить Activities tab, compact island behavior, supported sources, own timers/downloads, external completion watcher. Не обещать desktop Яндекс Музыку, если manual matrix не PASS.

- [ ] **Step 2: Обновить Permissions/How it works**

Уточнить: новых system permissions нет; downloads используют явный URL и выбранную folder; Calendar prompt прежний; cookies/auth/DRM не поддерживаются; background URLSession и watcher public APIs.

- [ ] **Step 3: Описать data/recovery**

`docs/activities.md`: priority, indicator overflow, settings defaults, JSON paths/schema overview, folder behavior, privacy, pause grace, recovery actions, known limitations.

- [ ] **Step 4: Проверить двуязычную согласованность**

Русский README — основной UX-текст, английский несёт те же факты. Paths/limits/defaults должны совпадать со spec/tests.

- [ ] **Step 5: Закоммитить docs**

```bash
git add README.md README.ru.md docs/activities.md
git commit -m "docs: explain Cyclop activities"
```

### Task 7: Финальный review и подготовка upstream

**Files:**
- All changed files reviewed; fixes get scoped commits.

- [ ] **Step 1: Сверить scope**

```bash
git diff --stat upstream/main...HEAD
git diff --name-status upstream/main...HEAD
git log --oneline upstream/main..HEAD
git status --short
```

Expected: только activity/tests/docs/CI + необходимые integration edits; нет version/release/build/personal data; `.superpowers/` untracked и не staged.

- [ ] **Step 2: Запустить независимый code review**

Проверить correctness, concurrency/main actor, background URLSession lifecycle, path traversal/overwrite, persistence, energy, localization, accessibility и reuse. Все actionable P0/P1/P2 исправить тестом сначала; после fixes повторить affected suite и full gate.

- [ ] **Step 3: Синхронизировать свежий upstream**

```bash
git fetch upstream
git merge upstream/main
```

Разрешать conflicts по смыслу; не перезаписывать новые maintainer changes. После merge повторить full automated + bundle + critical manual smoke.

- [ ] **Step 4: Выполнить final verification одним свежим запуском**

```bash
swift package clean
swift test --parallel
./Scripts/bundle.sh release
codesign --verify --strict build/Cyclop.app
git diff --check upstream/main...HEAD
git status --short
```

Expected: все команды PASS; status только `.superpowers/`.

- [ ] **Step 5: Запушить branch в fork**

```bash
git push origin codex/activity-center
```

Expected: fork branch up-to-date; GitHub Actions green.

### Task 8: Согласовать форму вклада и открыть PR

**Files:**
- GitHub issue/PR metadata only.

- [ ] **Step 1: Сначала показать maintainer готовый результат**

Открыть issue/discussion в upstream с краткой мотивацией, demo recording, архитектурной схемой, тест/energy evidence и ссылкой на fork branch. Задать один конкретный вопрос: предпочитает maintainer один полный PR или серию зависимых PR. Не просить согласовывать ещё неработающий mockup — fork уже полностью реализован и проверен.

- [ ] **Step 2: Если выбран один PR**

Открыть PR `mrvinil:codex/activity-center` → `akalikbergenov:main`. Title: `Добавить полноценную систему активностей возле чёлки`. Body: Problem, UX, Architecture, Permissions/privacy, Tests, Manual matrix, Energy, Screenshots/video, Known limitations. Сначала draft; после green review-ready.

- [ ] **Step 3: Если выбрана серия PR**

Создать clean dependent branches по проверенным commit boundaries: foundation → timers → downloads → media/meetings → UI/docs. Не использовать cherry-pick без повторного full test каждого tip. В описании каждого PR указать dependency и конечный demo branch.

- [ ] **Step 4: Проверить upstream PR gates**

CI green; no unresolved review threads; branch current with main; maintainer-facing docs concise; no version bump. Ответы на review подтверждать кодом/tests, а спорные предложения проверять до изменения.

- [ ] **Step 5: После merge**

Не удалять fork branch до подтверждения merge. После merge обновить fork main из upstream, закрыть planning issue, сохранить manual/energy reports в merged docs, cleanup local worktree только отдельным явным решением пользователя.

## Definition of Done

- Автоматические tests, release bundle, code signing и localization gate зелёные.
- Physical и synthetic hardware matrix заполнены без unresolved FAIL.
- Media matrix включает Apple Music, Spotify, browser и Яндекс Музыку с честными ограничениями.
- CPU/wakeups измерены; idle не получил постоянных timers.
- Privacy, permissions, storage failures и background recovery проверены.
- Feature полностью находится в fork до upstream PR.
- Upstream получил воспроизводимый review package без version/release changes.
