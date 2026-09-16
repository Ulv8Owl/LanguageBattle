#!/usr/bin/env python3
"""Заглушки для напоминаний: пять настроений персонажа и звук канала.

ЭТО ЗАГЛУШКИ, А НЕ ХУДОЖЕСТВЕННОЕ РЕШЕНИЕ. Настоящие пять рисунков и
настоящий звук даёт владелец проекта; скрипт нужен, чтобы до того момента
уведомления приходили С КАРТИНКОЙ И СО ЗВУКОМ, а не молча. Молчащий канал
и пустая картинка выглядят точно так же, как «функция не работает», — и
отличить одно от другого на телефоне нельзя.

Запуск: python3 tools/make_reminder_assets.py

Ничего, кроме стандартной библиотеки, не требуется: PIL и ffmpeg в
облачной сессии нет, а появляться зависимость ради пяти заглушек не должна.
"""

import math
import os
import struct
import wave
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, 'assets', 'branding', 'chameleon.png')
MASCOT_DIR = os.path.join(ROOT, 'assets', 'mascot')
RAW_DIR = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res', 'raw')
RES_DIR = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')

# Значок в строке состояния. Android рисует его СИЛУЭТОМ: цвета он
# выбрасывает и оставляет только прозрачность, поэтому цветная иконка
# приложения превратилась бы там в белое пятно.
NOTIFICATION_SIZES = {
    'drawable-mdpi': 24,
    'drawable-hdpi': 36,
    'drawable-xhdpi': 48,
    'drawable-xxhdpi': 72,
    'drawable-xxxhdpi': 96,
}

# Имена обязаны совпадать с MascotMood (lib/data/reminder_templates.dart):
# картинка ищется по имени настроения, а не по списку где-то рядом.
MOODS = {
    'cheerful': (0x7C, 0xE5, 0x77),
    'waiting': (0x6F, 0xB6, 0xFF),
    'worried': (0xFF, 0xC4, 0x4D),
    'sad': (0xB9, 0x8C, 0xFF),
    'restless': (0xFF, 0x8A, 0x4C),
}

SCALE = 8


def read_png(path):
    """Минимальный разбор PNG: 8 бит, RGBA, без чересстрочности."""
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'не PNG'
    pos, idat, header = 8, b'', None
    while pos < len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
        pos += 12 + length
    width, height, depth, color, _, _, interlace = header
    assert (depth, color, interlace) == (8, 6, 0), 'ожидался 8-битный RGBA без интерлейса'
    raw = zlib.decompress(idat)
    stride = width * 4
    out, prev, at = [], bytearray(stride), 0
    for _ in range(height):
        filt = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if filt == 1:
                line[i] = (line[i] + a) & 0xFF
            elif filt == 2:
                line[i] = (line[i] + b) & 0xFF
            elif filt == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        out.append(bytes(line))
        prev = line
    return width, height, out


def write_png(path, width, height, rows):
    raw = b''.join(b'\x00' + row for row in rows)

    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body
                + struct.pack('>I', zlib.crc32(kind + body) & 0xFFFFFFFF))

    open(path, 'wb').write(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b'')
    )


def tinted(rows, width, tint):
    """Перекрасить, сохранив светлоту: настроения должны отличаться на глаз."""
    out = []
    for row in rows:
        line = bytearray(row)
        for x in range(width):
            i = x * 4
            if line[i + 3] == 0:
                continue
            lum = (line[i] * 299 + line[i + 1] * 587 + line[i + 2] * 114) / 1000 / 255
            for c in range(3):
                base = line[i + c] / 255
                mixed = 0.45 * base + 0.55 * (tint[c] / 255) * (0.45 + 0.55 * lum)
                line[i + c] = max(0, min(255, round(mixed * 255)))
        out.append(bytes(line))
    return out


def upscaled(rows, width, factor):
    """NEAREST — ни одного смешанного пикселя, как и у иконок приложения."""
    out = []
    for row in rows:
        line = bytearray()
        for x in range(width):
            line.extend(row[x * 4:x * 4 + 4] * factor)
        for _ in range(factor):
            out.append(bytes(line))
    return out


def boxed(rows, width, height, size):
    """Уменьшение усреднением по площади.

    NEAREST здесь не годится: при сжатии 77->24 больше половины исходных
    пикселей не попадает ни в один выходной, и от тонкого силуэта
    остаются дыры. Усреднение учитывает их все.
    """
    out = []
    for y in range(size):
        line = bytearray()
        y0, y1 = y * height // size, max(y * height // size + 1, (y + 1) * height // size)
        for x in range(size):
            x0, x1 = x * width // size, max(x * width // size + 1, (x + 1) * width // size)
            total, count = 0, 0
            for sy in range(y0, y1):
                row = rows[sy]
                for sx in range(x0, x1):
                    total += row[sx * 4 + 3]
                    count += 1
            alpha = round(total / count) if count else 0
            line.extend((255, 255, 255, alpha))
        out.append(bytes(line))
    return out


def make_notification_icon():
    """Силуэт хамелеона для строки состояния."""
    width, height, rows = read_png(SOURCE)
    # Силуэт квадратный: у значка квадратное поле, и вписывать надо по
    # большей стороне, иначе рисунок растянется.
    side = max(width, height)
    pad_x, pad_y = (side - width) // 2, (side - height) // 2
    blank = bytes(side * 4)
    square = [blank] * pad_y
    for row in rows:
        square.append(bytes(pad_x * 4) + row + bytes((side - width - pad_x) * 4))
    square.extend([blank] * (side - height - pad_y))
    for folder, size in NOTIFICATION_SIZES.items():
        target = os.path.join(RES_DIR, folder)
        os.makedirs(target, exist_ok=True)
        path = os.path.join(target, 'ic_notification.png')
        write_png(path, size, size, boxed(square, side, side, size))
        print('%s  %dx%d' % (path, size, size))


def make_moods():
    width, height, rows = read_png(SOURCE)
    os.makedirs(MASCOT_DIR, exist_ok=True)
    for name, tint in MOODS.items():
        big = upscaled(tinted(rows, width, tint), width, SCALE)
        path = os.path.join(MASCOT_DIR, 'mood_%s.png' % name)
        write_png(path, width * SCALE, height * SCALE, big)
        print('%s  %dx%d' % (path, width * SCALE, height * SCALE))


def make_sound():
    """Искажённый звук уведомления: чистый звон, пропущенный через
    перегруз и огрубление разрядности. Ровно тем и отличается звук
    Duolingo от системного — он тот же звон, но «сломанный»."""
    rate, seconds = 44100, 0.85
    total = int(rate * seconds)
    samples = []
    for n in range(total):
        t = n / rate
        # Две ноты подряд, как у обычного уведомления.
        first = math.exp(-9.0 * t) * math.sin(2 * math.pi * 987.77 * t)
        late = max(0.0, t - 0.16)
        second = math.exp(-7.0 * late) * math.sin(2 * math.pi * 1318.51 * late) if t > 0.16 else 0.0
        # Расстроенный обертон — от него звук «плывёт».
        detune = 0.35 * math.exp(-6.0 * t) * math.sin(2 * math.pi * 1479.98 * t * 1.006)
        v = 0.6 * first + 0.6 * second + detune
        # Перегруз: мягкое насыщение до жёсткого ограничения.
        v = math.tanh(3.2 * v)
        samples.append(v)
    # Огрубление разрядности и частоты — «цифровая» грязь поверх звона.
    held, out = 0.0, []
    for n, v in enumerate(samples):
        if n % 3 == 0:
            held = round(v * 24) / 24
        out.append(held)
    peak = max(abs(v) for v in out) or 1.0
    os.makedirs(RAW_DIR, exist_ok=True)
    path = os.path.join(RAW_DIR, 'reminder.wav')
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        f.writeframes(b''.join(
            struct.pack('<h', int(max(-1.0, min(1.0, v / peak * 0.9)) * 32767)) for v in out))
    print('%s  %.2f c' % (path, seconds))


if __name__ == '__main__':
    make_moods()
    make_notification_icon()
    make_sound()
