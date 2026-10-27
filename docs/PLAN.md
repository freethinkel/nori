# nori: план PoC

Цель: прототип niri-подобного WM для macOS. Колонки, вертикальные воркспейсы, хоткеи. Анимация через WindowServer transform.

## Структура

- `loader.m` — копия loader из yabai (MIT, src/osax). В шапке указать источник и лицензию.
- `payload.m` — свой dylib для Dock. Сокет `/tmp/nori_$USER.socket`. Три команды: батч transform на кадр, move, alpha/order.
- `main.swift` — демон: колонки, вертикальные воркспейсы, хоткеи через CGEvent tap, CVDisplayLink шлёт transform.

## Шаги

1. Собрать `payload.m` с `-arch arm64e` в dylib.
2. Собрать `loader.m`, проверить что он грузит payload в Dock (только когда система настроена, см. ниже).
3. Написать `main.swift`: модель колонок, раскладка, хоткеи.
4. Связать демон с payload через сокет.
5. Проверка: одно окно, потом две колонки, потом переключение воркспейсов.

## Предусловия (делает пользователь, не агент)

- Debugging Restrictions: disabled. Без этого `task_for_pid` на Dock не работает.
- Filesystem Protections: disabled.
- boot-args `-arm64e_preview_abi`. Без этого Dock (arm64e) не загрузит чужой dylib.

Эти шаги меняют защиту системы и требуют Recovery. Агент их не выполняет.

## Не делаем

- Сигнатурный поиск приватных глобалов Dock (нужен только для нативных Spaces).
- Замену yabai layout. На время теста: `yabai -m config layout float` или `yabai --stop-service`.

## Откат

- `sudo yabai --uninstall-sa`, когда собственный payload заработает и не нужен.

## Открыто

- Вызовы SLS взяты из yabai, сигнатуры нужно проверить на текущей macOS (27).
- Тестировать только на своей машине, без сторонних окон в критичных задачах.
