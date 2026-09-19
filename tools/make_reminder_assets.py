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
    'angry': (0xFF, 0x5A, 0x3C),
    'sad': (0xB9, 0x8C, 0xFF),
    'crying': (0x5F, 0xD0, 0xE8),
    'lost': (0x8A, 0x8A, 0x92),
    'restless': (0xFF, 0x8A, 0x4C),
}

# ═══ ЗВУКИ: ПО ОДНОМУ НА СРОК ═══
#
# Разные потому, что уведомление, звучащее всегда одинаково, перестают
# слышать на третий день: рука тянется смахнуть его ещё до того, как
# глаз прочёл. Разный звук — единственное, что успевает сказать «это
# другое» ДО чтения.
#
# Android помнит звук КАНАЛА и менять его у существующего не даёт,
# поэтому каждому сроку нужен свой канал — см. lib/core/reminders.dart.
#
# Устроены все одинаково: чистый звон, пропущенный через перегруз и
# огрубление разрядности. Отличаются рисунком высоты — он и читается как
# настроение.
#
# segments: (частота в начале, частота в конце, старт, длительность, громкость)
SOUNDS = {
    # «Эй! Эй! Эй!» — торопит, но не пугает.
    'voice_endofday': dict(
        segments=[(740, 900, 0.00, 0.11, 1.0),
                  (840, 1010, 0.16, 0.11, 0.95),
                  (940, 1250, 0.32, 0.16, 0.9)],
        drive=2.8, crush=22, vibrato=(0.0, 0.0), seconds=0.60,
    ),
    # Злость: два низких удара, грубо и коротко.
    'voice_second': dict(
        segments=[(330, 210, 0.00, 0.22, 1.0),
                  (290, 170, 0.28, 0.30, 0.95)],
        drive=5.5, crush=12, vibrato=(0.0, 0.0), seconds=0.66,
    ),
    # Обида: две ноты вниз, медленно.
    'voice_third': dict(
        segments=[(560, 540, 0.00, 0.30, 0.9),
                  (450, 430, 0.34, 0.42, 0.85)],
        drive=2.2, crush=20, vibrato=(4.0, 0.012), seconds=0.82,
    ),
    # Плач: один длинный съезд вниз с дрожью.
    'voice_fifth': dict(
        segments=[(760, 360, 0.00, 0.75, 0.95)],
        drive=2.6, crush=18, vibrato=(9.0, 0.055), seconds=0.82,
    ),
    # Отчаяние: низко, глухо, с большой паузой внутри.
    'voice_week': dict(
        segments=[(240, 215, 0.00, 0.45, 0.8),
                  (200, 185, 0.60, 0.60, 0.6)],
        drive=1.8, crush=14, vibrato=(2.5, 0.01), seconds=1.25,
    ),
    # Тревога: частые высокие писки, самый настойчивый из всех.
    'voice_burning': dict(
        segments=[(1180, 1180, 0.00, 0.09, 1.0),
                  (1480, 1480, 0.13, 0.09, 1.0),
                  (1180, 1180, 0.26, 0.09, 1.0),
                  (1480, 1600, 0.39, 0.18, 1.0)],
        drive=4.0, crush=16, vibrato=(0.0, 0.0), seconds=0.62,
    ),
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


def make_widget_preview():
    """Картинка виджета для списка при долгом нажатии на рабочий стол.

    ОТДЕЛЬНЫМ ФАЙЛОМ, А НЕ ИКОНКОЙ ПРИЛОЖЕНИЯ. Иконка у нас — адаптивная
    (XML в mipmap-anydpi-v26), и лаунчеры рисуют её в списке виджетов
    по-разному, вплоть до пустого места. Обычный PNG рисуют все
    одинаково, а пустое место в списке неотличимо от «виджета нет».
    """
    width, height, rows = read_png(SOURCE)
    mascot = upscaled(tinted(rows, width, MOODS['waiting']), width, 2)
    mw, mh = width * 2, height * 2

    out_w, out_h = 360, 160
    radius = 28
    bg = (0xFF, 0xD4, 0x00)
    ink = (0x0D, 0x0D, 0x10)

    canvas = [bytearray(out_w * 4) for _ in range(out_h)]
    for y in range(out_h):
        for x in range(out_w):
            # Скруглённые углы: точка внутри, если она не вышла за
            # четверть круга в своём углу.
            cx = radius - x if x < radius else (x - (out_w - radius - 1) if x > out_w - radius - 1 else 0)
            cy = radius - y if y < radius else (y - (out_h - radius - 1) if y > out_h - radius - 1 else 0)
            if cx * cx + cy * cy > radius * radius:
                continue
            i = x * 4
            canvas[y][i:i + 4] = bytes(bg + (255,))

    def bar(top, left, w, h, alpha):
        for y in range(top, min(top + h, out_h)):
            for x in range(left, min(left + w, out_w)):
                i = x * 4
                if canvas[y][i + 3] == 0:
                    continue
                canvas[y][i:i + 4] = bytes(ink + (alpha,))

    # Две полоски вместо текста: список виджетов показывает картинку
    # мелко, и настоящие буквы там всё равно не прочесть.
    bar(46, 24, 150, 16, 255)
    bar(74, 24, 190, 10, 150)
    bar(92, 24, 120, 10, 150)

    at_x, at_y = out_w - mw - 20, (out_h - mh) // 2
    for y in range(mh):
        ty = at_y + y
        if not (0 <= ty < out_h):
            continue
        row = mascot[y]
        for x in range(mw):
            tx = at_x + x
            if not (0 <= tx < out_w):
                continue
            src = row[x * 4:x * 4 + 4]
            if src[3] == 0 or canvas[ty][tx * 4 + 3] == 0:
                continue
            canvas[ty][tx * 4:tx * 4 + 4] = src

    target = os.path.join(RES_DIR, 'drawable-nodpi')
    os.makedirs(target, exist_ok=True)
    path = os.path.join(target, 'widget_preview.png')
    write_png(path, out_w, out_h, [bytes(r) for r in canvas])
    print('%s  %dx%d' % (path, out_w, out_h))


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
    """Настроения — И В АССЕТЫ, И В РЕСУРСЫ ANDROID.

    В ассеты — потому что их показывает сам экран приложения. В ресурсы
    — потому что уведомление и виджет рисуются, когда приложения нет ни
    в каком виде: читать ассеты Flutter там нечем и некому. Ресурс же
    находится по имени и всегда на месте.
    """
    width, height, rows = read_png(SOURCE)
    os.makedirs(MASCOT_DIR, exist_ok=True)
    drawable = os.path.join(RES_DIR, 'drawable-nodpi')
    os.makedirs(drawable, exist_ok=True)
    for name, tint in MOODS.items():
        big = upscaled(tinted(rows, width, tint), width, SCALE)
        for path in (
            os.path.join(MASCOT_DIR, 'mood_%s.png' % name),
            # Имя ресурса должно совпадать с MascotMood, как и имя ассета:
            # и уведомление, и виджет ищут его по имени настроения.
            os.path.join(drawable, 'mascot_%s.png' % name),
        ):
            write_png(path, width * SCALE, height * SCALE, big)
            print('%s  %dx%d' % (path, width * SCALE, height * SCALE))


def make_sound(name, spec):
    """Один звук по описанию из SOUNDS."""
    rate = 44100
    seconds = spec['seconds']
    total = int(rate * seconds)
    vib_rate, vib_depth = spec['vibrato']
    drive, crush = spec['drive'], spec['crush']

    raw = [0.0] * total
    for f0, f1, start, dur, amp in spec['segments']:
        first = int(start * rate)
        length = int(dur * rate)
        phase = 0.0
        for n in range(length):
            at = first + n
            if at >= total:
                break
            k = n / length
            freq = f0 + (f1 - f0) * k
            if vib_depth:
                freq *= 1.0 + vib_depth * math.sin(2 * math.pi * vib_rate * (n / rate))
            phase += 2 * math.pi * freq / rate
            raw[at] += amp * math.exp(-4.5 * k) * math.sin(phase)

    # Перегруз и огрубление — та самая «искажённость», ради которой всё
    # и затевалось: чистый синус звучит как будильник из телефона 2009
    # года, искажённый — как голос персонажа.
    held, out = 0.0, []
    for n, v in enumerate(raw):
        v = math.tanh(drive * v)
        if n % 3 == 0:
            held = round(v * crush) / crush
        out.append(held)

    peak = max(abs(v) for v in out) or 1.0
    os.makedirs(RAW_DIR, exist_ok=True)
    path = os.path.join(RAW_DIR, '%s.wav' % name)
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        f.writeframes(b''.join(
            struct.pack('<h', int(max(-1.0, min(1.0, v / peak * 0.9)) * 32767)) for v in out))
    print('%s  %.2f c' % (path, seconds))


def make_sounds():
    for name, spec in SOUNDS.items():
        make_sound(name, spec)


if __name__ == '__main__':
    make_moods()
    make_widget_preview()
    make_notification_icon()
    make_sounds()
