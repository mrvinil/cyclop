# Ручная матрица media-провайдеров

## Назначение

Матрица проверяет общий контракт системного Now Playing для поддерживаемых
media-провайдеров. Она не подтверждает выполнение проверок в headless-среде:
каждая строка начинается со статуса `Не выполнено` и должна быть заполнена на
машине с соответствующим приложением и воспроизводимым контентом.

## Предусловия

- Собрать и запустить актуальную версию Cyclop на macOS.
- Открыть существующую развернутую media-панель Cyclop.
- Подготовить минимум два трека (или два медиа-элемента) для проверки смены.
- Для браузера включить воспроизведение в обычной вкладке без Accessibility
  разрешения, scraping и private API.
- Перед проверкой fallback намеренно сделать Now Playing helper недоступным
  только в контролируемой тестовой среде.

## Критерии прохождения

Для строки без fallback ожидается, что system Now Playing показывает корректные
название, исполнителя и альбом, artwork появляется в существующей развернутой
media-панели, play/pause и допустимый skip выполняются, смена трека обновляет
карточку, а пауза скрывает её ровно через 15 секунд. Текст приватности должен
оставаться видимым в предусмотренном интерфейсом месте.

При недоступном helper источник публикует диагностику:
`Системная музыка недоступна; доступны только Apple Music и Spotify`.
Apple Music и Spotify могут появиться через прямой scripting fallback. Для
браузеров и Яндекс Музыки это не обещает воспроизведение: это degraded mode и
ограничение интеграции macOS, а не полная поддержка. Не добавлять для обхода
ограничения Accessibility, scraping или private API.

| Провайдер | Контекст | Версия macOS/приложения | Проверки | Статус | Фактический результат |
| --- | --- | --- | --- | --- | --- |
| Apple Music | Нативное приложение Music | Не выполнено | metadata; artwork в existing expanded media pane; play/pause; skip capability; смена трека; ровно 15 s pause grace; privacy text; fallback diagnostic | Не выполнено | Не выполнено |
| Spotify | Нативное приложение Spotify | Не выполнено | metadata; artwork в existing expanded media pane; play/pause; skip capability; смена трека; ровно 15 s pause grace; privacy text; fallback diagnostic | Не выполнено | Не выполнено |
| Safari media | Вкладка Safari с медиа | Не выполнено | metadata; artwork в existing expanded media pane; play/pause; skip capability; смена трека; ровно 15 s pause grace; privacy text; fallback diagnostic | Не выполнено | Не выполнено |
| Chrome media | Вкладка Google Chrome с медиа | Не выполнено | metadata; artwork в existing expanded media pane; play/pause; skip capability; смена трека; ровно 15 s pause grace; privacy text; fallback diagnostic | Не выполнено | Не выполнено |
| Яндекс Музыка | В браузере | Не выполнено | metadata; artwork в existing expanded media pane; play/pause; skip capability; смена трека; ровно 15 s pause grace; privacy text; fallback diagnostic | Не выполнено | Не выполнено |
| Яндекс Музыка desktop | Нативный клиент, только если он публикует system Now Playing | Не выполнено | metadata; artwork в existing expanded media pane; play/pause; skip capability; смена трека; ровно 15 s pause grace; privacy text; fallback diagnostic | Не выполнено | Не выполнено |

## Ограничение desktop Яндекс Музыки

Строка desktop-клиента применима только при публикации системного Now Playing.
Если клиент его не публикует, зафиксировать это в «Фактическом результате» как
ограничение macOS integration. Cyclop не получает данные через scraping,
Accessibility или private API.
