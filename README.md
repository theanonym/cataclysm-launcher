## Общая информация
Кроссплатформенный лаунчер с рядом дополнительных функций.
- Проверка наличия нового билда
- Обновление игры с сохранением сейвов и настроек
- Установка свежей версии тайлсета DeadPeople
- Установка 2ch sound pack и 2ch soundtrack
- Создание резервной копии и восстановление миров

## Использование

### Windows
Для винды нужно скачать и установить [Stawberry Perl](http://strawberryperl.com/). Он включет в себя интерпретатор и все необходимые модули.
Далее поместить `cata.pl` в папку с игрой (либо пустую папку, если нужно скачать игру) и запускать в командной строке:
```
perl cata.pl --help
```

### Linux
Можно клонировать эту репу в папку с игрой и линкануть скрипт:
```
cd Cataclysm
git clone https://github.com/theanonym/cataclysm-launcher.git
ln -s cataclysm-launcher/cata.pl cata.pl

perl cata.pl --help
```

В случае ошибки "Can't locate ХХХ/XXX.pm" нужно установить `cpanminus` и с его помощью стянуть недостающие модули (от рута):
```
curl -L https://cpanmin.us | perl - App::cpanminus
cpanm --notest XXX::XXX
```
Должно хватить этих:
```
cpanm --notest File::Slurp File::Find::Rule List::MoreUtils Archive::Extract LWP JSON
```