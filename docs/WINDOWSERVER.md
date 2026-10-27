# WindowServer / SkyLight: что найдено

Заметки по приватным API, которые использует или может использовать niri-mac. Проверено на macOS 27 (Darwin 27.0.0), Apple Silicon.
«Проверено» = видели своими глазами; «не проверено» = вывод из дизассемблера или догадка.

## Как смотреть

- Логи payload: `/usr/bin/log show --last 1h --predicate 'process == "Dock" AND eventMessage CONTAINS "niri-mac"' --style compact`.
  В zsh просто `log` — встроенная команда, она молча ничего не покажет. Нужен полный путь `/usr/bin/log`.
- Экспорты SkyLight (он в shared cache, `nm` не поможет):
  `dyld_info -exports /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight | awk '{print $NF}' | grep -i <что-то>`
- Дизассемблер функции SkyLight без Dock: любой свой бинарь, `lldb -b ./bin -o "b main" -o run -o 'expr (void*)dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",1)' -o "dis -n <Функция>"`.
- Какие функции Dock вызывает во время действия: подключиться к Dock и поставить автопродолжаемые брейкпоинты (с выключенным Debugging Restrictions это работает без sudo, Dock не падает):
  ```
  breakpoint set -n SLSTransactionSetSpaceShape -n SLSTransactionSetSpaceTransform -G1
  breakpoint command add 1
  frame info
  register read x1 x2 x3 d0 d1 d2 d3
  DONE
  process continue
  ```
  `lldb -p $(pgrep -x Dock) -s file.lldb > out &`, затем действие (например `osascript -e 'tell application "System Events" to key code 19 using {option down}'`), затем `pkill -f "lldb -p"`.
- Space окна и активный Space из демона: `CGSGetActiveSpace(CGSMainConnectionID())`, `CGSCopySpacesForWindows(cid, 7, [wid])` — экспортируются CoreGraphics, линкуются из Swift через `@_silgen_name` без доп. флагов. Проверено.

## Переключение Spaces в Dock

Проверено через лог хука и lldb. Переключение (Ctrl/Option+N, свайп) Dock делает сам, кадр за кадром, примерно раз в 16 мс (60 Гц), около 15 кадров на переход:

1. `SLSTransactionWillSwitchSpaces`
2. `SLSTransactionShowSpace` для нового Space
3. каждый кадр, для старого и нового Space:
   - `SLSTransactionSetSpaceTransform(transaction, sid, u32 = 4, const CGAffineTransform *)` — чистый сдвиг, `tx` плавно от 0 до ±ширины дисплея в пикселях (3072 на этом экране), соседние Space сдвинуты на ±3072.
   - `SLSTransactionSetSpaceShape(transaction, sid, CGRegionRef)` — клип Space, новый регион на каждый кадр. Именно он даёт чёрную полосу, если transform сделать вертикальным, а клип оставить горизонтальным.
   - `SLSTransactionSetSafeApertureSpaceReveal(transaction, sid, d0 = прогресс 0…1, …)` — что-то про область «чёлки» (safe aperture). Не разбирали.
4. `SLSTransactionSetManagedDisplayCurrentSpace`, `SLSTransactionHideSpace` для старого, `SLSTransactionSetSpaceOrderingWeight`.

Transform Space только 2D-аффинный: сдвиг и масштаб возможны (так работает Mission Control), перспектива — нет.
Проверено дизассемблером: `SLSTransactionSetSpaceTransform` читает из указателя ровно 6 double (CGAffineTransform), `u32` кодируется отдельным числом (флаг, смысл не выяснен). `SLSSpaceSetTransform` тоже берёт 2D (два q-регистра = 4 double + tx/ty). Экспортов вида `Space…3D` / `Space…Warp` в SkyLight нет.
`SLSSetSessionSwitchCubeAnimation(bool)` — только флаг «куб при быстром переключении пользователей», уходит на server root port. Для Spaces не годится.
Вывод: 3D для Space делается только через окна — `SetWindowTransform3D` каждому окну обоих Space (обои — тоже окна).

Хук в `payload/payload.m` (`hook_space_transform`) патчит первые 16 байт `SLSTransactionSetSpaceTransform` в копии SkyLight внутри Dock и превращает горизонтальный сдвиг в вертикальный. Работает: `vertical spaces on (kr=0)`, вызовы видны в логе. Пролог на macOS 27: `pacibsp; stp d9,d8,[sp,#-0x40]!; stp x22,x21,[sp,#0x10]; stp x20,x19,[sp,#0x20]`.
Чтобы убрать чёрную полосу, нужно так же перехватить `SLSTransactionSetSpaceShape` и двигать клип по вертикали. Не сделано.

## Системные шорткаты Spaces

«Switch to Desktop 1…N» — `com.apple.symbolichotkeys`, ключи 118, 119, 120, 121, 122 (рабочие столы 1–5). Параметры `(символ, keycode, модификаторы)`, Option = 524288, Ctrl = 262144. Keycode цифр 1–5 в US-раскладке: 18, 19, 20, 21, 23.
Включить без UI: `defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 118 '<dict>…</dict>'`, затем `/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u`. Сейчас 118–122 включены на Option+1…5.

## Окна

- Перемещение (`SLSMoveWindowWithGroup` / транзакции, даже из Dock) WindowServer ограничивает краем экрана. Проверено: окно, отправленное на y = 3000, встало на y = 1541 (часть осталась на экране); на y = −3000 — встало на y = 0. Спрятать окно за экран перемещением нельзя.
- `SLSSetWindowTransform(cid, wid, CGAffineTransform)` — 2D. Матрица обратная (экран → окно), как у yabai. Не перепроверяли.
- **`SLSTransactionSetWindowTransform3D(transaction, wid, const double m[16])`** — 4×4 transform окна (раскладка CATransform3D, 16 double подряд). Сигнатура из дизассемблера: `x0` transaction, `w1` wid, `x2` указатель, читаются смещения 0x00…0x78. В payload: команда `D wid m11 … m44`.
  Проверено на живом окне (Dock, macOS 27):
  - Матрица **обратная**: точка экрана → точка окна. `m41=300, m42=150` сдвигает окно на 300 влево и 150 вверх; `m11=m22=2` уменьшает окно вдвое.
  - Единицы — точки. Начало координат — **левый верхний угол окна** (масштаб сжимает окно к этому углу).
  - Конвенция строк, как у CATransform3D: `x_окна = x·m11 + y·m21 + m41`, `y_окна = x·m12 + y·m22 + m42`, `w = x·m14 + y·m24 + m44`.
  - Точки экрана лежат в z=0, поэтому `m34` ничего не даёт. Перспектива задаётся через `m14/m24`, то есть это 2D-гомография. Рецепт: построить прямую гомографию H (3×3, столбцы, локальные координаты окна → экран), взять G = H⁻¹, нормировать на G[2][2] и разложить: `m11,m21,m41 = G[0]`, `m12,m22,m42 = G[1]`, `m14,m24,m44 = G[2]`, `m33 = 1`.
  - Поворот вокруг вертикальной оси через центр окна с перспективой (θ = ±0.6, d = 1500) работает: живое окно в 3D, рисуется и за пределами своих bounds. Скрипт: H = T(c)·P·T(−c), P = `[[cos θ,0,0],[0,1,0],[sin θ/d,0,1]]`.
  - Единичная матрица возвращает окно как было.
- `SLSSetWindowWarp` / `SLSTransactionSetWindowWarp` — сеточное искажение окна (эффект «джинн»). Не проверено.
- `SLSSetSessionSwitchCubeAnimation` — куб быстрого переключения пользователей. Не разбирали.
- Ещё есть: `SLSSetWindowTransforms` (пачкой), `SLSTransactionSetSpaceAlpha`, `SLSCreateGenieWindowAnimation`, `SLSSetWindowAnimationProgress`, `SLSAddWindowFilter` / `SLSNewCIFilterByName` (CI-фильтры на окна).
- `CGWindowListCopyWindowInfo` с `.optionOnScreenOnly` показывает только окна текущего Space; окно на другом Space в `.optionAll` может иметь bounds (0, 0).

## Идеи, ещё не сделаны

- Свой эффект переключения настоящих Spaces: оставить само переключение Dock (его состояние: Mission Control, строка меню), а в хуке подменять transform и shape обоих Space; для куба — гасить transform Space и вращать окна обоих Space через `SetWindowTransform3D`, прогресс брать из `tx` Dock.
- Overview как в niri: масштаб окон (или Space) через transform.
