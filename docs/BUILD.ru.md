# Сборка и требования

Установите Xcode 16.4 или новее и выберите его каталог разработчика. Выполните `swift build` в папке проекта. Для `bash scripts/build-preview.sh` дополнительно нужен Runtime, соответствующий Config/runtime-manifest.json: проверяются все размеры и SHA-256, компоненты не скачиваются. Его путь можно задать LEKTIEN_RUNTIME_DIRECTORY. Модели и медиаинструменты исключены из Git. Манифест описывает существующий локальный комплект, а не публичный сервис загрузки. Автоматическое воспроизводимое получение окружения пока не реализовано.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
# With the separately prepared runtime:
LEKTIEN_RUNTIME_DIRECTORY=/path/to/Runtime bash scripts/build-preview.sh
```

Kseniya сейчас ожидает готовое окружение Python в ~/Library/Application Support/SRTVoiceover/.venv-silero с Python/Torch/Silero и моделью голоса. Codex CLI нужно установить и авторизовать отдельно. Используется также системный Ruby. Сборка исходников сама эти компоненты не устанавливает. Учётные данные и виртуальное окружение между компьютерами не копируйте.

Только исходники, готового установщика нет. macOS 15+, Apple Silicon, Xcode 16.4+ / Swift 6.1. Для полной работы нужны отдельный Runtime, Codex CLI с входом ChatGPT и Python/Torch/Silero Kseniya. Установка на чистый Mac пока не проверена.
