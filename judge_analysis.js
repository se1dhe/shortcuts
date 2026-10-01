const videoAnalysis = {
  "judgeVideos": [
    {
      "id": "ya-nanyal-tebya",
      "filename": "я-нанял-тебя-потому-что-знаешь-что-ты-бы.mp4",
      "technical": {
        "duration": 10.1,
        "resolution": "1920x1080",
        "lufs": -35.0,
        "cutCount": 4,
        "averageShotDuration": 2.02
      },
      "issues": [
        "Неверное разрешение (16:9 вместо 1:1 или 9:16), пропущен этап кадрирования (crop).",
        "Очень низкая громкость (-35 LUFS)."
      ]
    },
    {
      "id": "ya-zaplashu",
      "filename": "я-заплачу-за-это-если-ты-не-дашь-мне-раб.mp4",
      "technical": {
        "duration": 21.8,
        "resolution": "1080x1080",
        "lufs": -34.3,
        "cutCount": 4,
        "averageShotDuration": 4.35
      }
    },
    {
      "id": "vy-hotite",
      "filename": "вы-хотите-справедливости-хорошо.mp4",
      "technical": {
        "duration": 25.3,
        "resolution": "1080x1080",
        "lufs": -27.4,
        "cutCount": 12,
        "averageShotDuration": 1.94
      }
    },
    {
      "id": "moya-mama",
      "filename": "моя-мама-скончалась-сегодня-ага-черт-из-.mp4",
      "technical": {
        "duration": 24.8,
        "resolution": "1080x1080",
        "lufs": -33.7,
        "cutCount": 8,
        "averageShotDuration": 2.76
      }
    },
    {
      "id": "ty-zaplaniroval",
      "filename": "ты-запланировал-это-чтобы-я-проиграл.mp4",
      "technical": {
        "duration": 90.0,
        "resolution": "1080x1080",
        "lufs": -46.4,
        "cutCount": 20,
        "averageShotDuration": 4.28
      },
      "issues": [
        "Громкость экстремально низкая (-46.4 LUFS).",
        "Слишком длинные кадры (4.28 сек) для 90-секундного формата, не держит внимание."
      ]
    }
  ],
  "etalonVideos": [
    {
      "files": ["2008.mp4", "2009.mp4", "2013.mp4", "васаби-2001.mp4", "страх-и-ненависть-в-лас-вегасе-1998.mp4", "шоссе-в-никуда-1997.mp4"],
      "technical": {
        "durationRange": "53-60 sec",
        "resolution": "1080x1080",
        "lufsRange": "-21.8 to -10.0",
        "averageShotDurationRange": "0.35 to 0.77 sec"
      }
    }
  ],
  "globalConclusions": {
    "whyEtalonWorks": [
      "Высокая плотность монтажа (каждые 0.3-0.7 секунд склейка).",
      "Оптимальный уровень громкости и саунд-дизайна (от -21 до -10 LUFS)."
    ],
    "whyJudgeFails": [
      "Пропущен этап вертикального/квадратного кадрирования у некоторых файлов (1920x1080).",
      "Экстремально низкая громкость (от -27 до -46 LUFS), нет фонового напряжения.",
      "Вялый монтаж (средняя длина кадра 2-4 секунды вместо < 1 сек).",
      "90-секундный ролик не имеет достаточной динамики и хуков."
    ]
  }
};

export default videoAnalysis;
