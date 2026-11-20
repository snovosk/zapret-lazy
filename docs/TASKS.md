# Задачи zlazy

## Открытые задачи

### Проверка после перезагрузки и аварии

- Перезагрузить Windows и проверить фактический AtStartup Engine до logon;
  задача зарегистрирована, но полный reboot в этом прогоне не выполнялся.
  Ожидаемо в журнале: `Autopilot Boot` → (при позднем Wi-Fi
  `NetworkStillDown`) → `UpdateSkipped`/`UpdateProvisioned` → тест или пауза VPN.
- Сон/гибернация дольше 30 мин: ожидаемо `Service MonitorExit reason=wake` →
  `Autopilot Maintenance wake=True updateDue=True ...`. Живьём не проверено.
- Проверить очистку собственного orphaned winws после аварийного завершения
  engine. Сейчас подтверждён нормальный `shutdown`, а не `kill -9`/power loss.

## Выполнено

### Установщик: отзывчивость и тонкая шкала прогресса

- Установка и удаление выполняются отдельным worker, а не в UI-потоке.
- Рыжая полоса `#E8720C` высотой 3 px отражает реальные этапы из журнала и
  доходит до 100% только после успешного завершения.
- Проверены изолированные GUI-сценарии install/uninstall; системные компоненты
  mock-worker не изменял.

### Измерения: исправлен критерий 18/36

- Причина найдена: stock засчитывает `curl exit code = 0`, lazy дополнительно
  требовал HTTP 2xx/3xx. Шесть стабильно «падающих» целей возвращали 403/404:
  Discord Gateway/CDN/Updates, ytimg, googlevideo redirect, gstatic.
- Теперь критерий совпадает со stock, а HTTP-коды пишутся в
  `Engine TargetResult ... codes=...` для диагностики.
- Живой результат: ALT `36/36 fullyGreen=True`; полный цикл дал 10 зелёных
  стратегий, лучшая — `general (ALT).bat`, 36/36.
- Проверки парсера, SYSTEM/user curl, bin/winws hashes и запуск через `.bat`
  не объясняли разрыв; запуск через `.bat` оставлен для соответствия stock.

### Background winws без постоянной службы

- `Install-ZapretService` сохранено как compatibility-имя, но создаёт фоновый
  процесс через stock `.bat`, а не Windows service.
- Engine владеет процессом, watchdog перезапускает его; `Get-ZapretServiceState`
  отражает только управляемый winws из `zlazy-core\bin`.
- `shutdown` останавливает engine и winws. Проверено: до — два zlazy + winws;
  после — только tray, winws отсутствует, служба zapret отсутствует.
- Следующий запуск восстанавливает стратегию. Служба `zapret` только удаляется
  как legacy и больше не создаётся.

### Автозапуск и быстрые настройки

- Engine зарегистрирован `AtStartup` от SYSTEM, Tray — `AtLogon`.
- `setoption` исправлен: hashtable `ApplyOptions` теперь читается корректно.
- Проверено `OptionsRequested → Preflight → ProcessStarted → OptionsApplied`
  без нового `TestsStarted`; Game Filter восстановлен в `all`.
