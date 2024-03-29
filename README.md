## Общая информация
Кроссплатформенный лаунчер с рядом дополнительных функций.

Игра:
- Запуск (`--launch`)
- Проверка наличия нового билда (`--check`)
- Вывод списка изменений в последних билдах (`--changelog`)
- Обновление игры с сохранением сейвов и настроек (`--update`)

Моды:
- Установка модов (`--mod [ссылка на гитхаб]`)
- Обновление модов, указанных в `launcher_config.json` (`--update-mods`)

Сейвы:
- Создание резервной копии и восстановление миров (`--save`, `--load`)
- Копирование персонажа в другой мир (`--copy-char`)

Команды можно комбинировать.

## Использование

### Windows
Для винды нужно скачать и установить [Stawberry Perl](http://strawberryperl.com/). Он включет в себя интерпретатор и все необходимые модули.
Далее поместить папку `cataclysm-launcher` в папку с игрой (либо в пустую папку, если нужно скачать игру) и запускать в командной строке:
```bat
chdir cataclysm-launcher
perl cata.pl --help
```

### Linux
Можно клонировать эту репу в папку с игрой:
```bash
cd Cataclysm
git clone https://github.com/theanonym/cataclysm-launcher.git
cd cataclysm-launcher
./cata.pl --help
```

В случае ошибки "Can't locate ХХХ/XXX.pm" нужно установить `cpanminus` и с его помощью стянуть недостающие модули (от рута):
```bash
curl -L https://cpanmin.us | perl - App::cpanminus
cpanm --notest XXX::XXX
```
Команда для установки всех модулей сразу:
```bash
cpanm --notest File::Slurp File::Find::Rule List::MoreUtils Archive::Extract LWP JSON HTML::Entities Date::Parse
```
