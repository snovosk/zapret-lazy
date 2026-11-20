# Актуализация из `upd/` — 2026-11-19

## Перенесено

- **Виджет v2:** карточка 278×186, степперы Strategy / Game Filter / IPSet,
  анимация и mouse wheel, лиса в шапке, версия payload в футере.
- **Адаптивный трей:** лиса с бейджем состояния; прежние исправления popup,
  FormClosed, null-owner menu и GDI-дескрипторов сохранены.
- **Команда `setoption`:** изменение `gameFilterMode` и `ipsetMode` через
  whitelist, сохранение и повторный цикл проверки.
- **Диагностика движка:** `TargetResult`, `UnexpectedWinwsCount`,
  `WinwsExitedEarly`, `WinwsStopped count=0`.
- **Установщик:** интерактивное меню, автозапуск после установки, `/NoStart`,
  остановка компонентов перед upgrade, setup.log, защита от native stderr,
  исправление вложенных папок и отсутствующего диска donor.
- **Launcher:** ярлык `Zapret Lazy.lnk` и его удаление при unregister.
- **Сборка:** иконка `assets/zapret-lazy.ico` в трёх exe; assets включены в
  установочный пакет.
- **Документация:** README, CHANGELOG, design/spec и artboards; дополнительно
  синхронизированы CONVENTIONS, ARCHITECTURE и SECURITY с `setoption`.

## Исправлено при переносе

- `Resolve-TrayCommand` возвращал `$true` после исключения `Save-Config`.
  Это запускало Retest без применённой настройки. Теперь ветка ошибки
  возвращает `$false`; проверено симуляцией сбоя.

## Ошибки проверочного harness

Это ошибки тестового окружения, а не дефекты приложения; исправлены и повторный
прогон успешен:

1. Команды были переданы как hashtable, хотя реальный канал создаёт
   `PSCustomObject` из JSON. Первая валидная команда была отклонена. Harness
   переведён на JSON round-trip.
2. После изоляции TrayApp в dynamic module `$PSScriptRoot` был пуст. Импорт
   Config в harness удалён, `Get-Root` явно направлен в корень проекта.
3. Проверка wrap ожидала переход `all → udp` за один шаг, пропуская `disabled`.
   Добавлены промежуточная проверка и второй шаг.

## Проверки после переноса

- Source и merged PowerShell parse: PASS.
- `build/Build-Exe.ps1`: PASS; все exe имеют версию `1.1.0.0`.
- `setoption`: сохранение, status, whitelist, case-sensitivity и сбой записи — PASS.
- Степперы: sync, next, previous, wrap, disabled — PASS.
- Четыре адаптивные иконки 32×32 — PASS.
- Визуальный render 278×186 с assets — PASS (`artifacts/update-widget.png`).

## Не перенесено

- `upd/settings.json`: локальные настройки не должны перезаписывать текущие.
- `upd/logs/`: runtime-диагностика другой копии, не исходный код.
- Готовые exe, `build/package.zip`, `build/merged/`: пересобраны из исходников.
- Временные screenshots и lock-файлы дизайна не нужны для работы.

## Открытая ошибка из `upd`

Разница результатов stock zapret и lazy на заблокированной сети (`36/36` против
`18/36`) **не решена**. TCP timestamps и user-list hypotheses уже опровергнуты
логами в `upd`; добавленная инструментация перенесена, но новый живой сетевой
прогон с ней в этой синхронизации не выполнялся. Happ/TUN на текущей машине
также меняет условия измерения.
