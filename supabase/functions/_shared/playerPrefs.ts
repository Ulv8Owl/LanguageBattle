/**
 * Где в раунде участвует модель — решает сам игрок.
 *
 * ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ ПЕРЕМЕННЫХ ОКРУЖЕНИЯ. JUDGE_ENABLED и
 * EXPLAIN_PREFER_DATASET остались, но у них другая роль: это рубильник
 * оператора («провайдер лежит, выключить всем»), а не выбор игрока. Их
 * беда в том, что менять их — значит передеплоивать функцию, и сравнить
 * два режима на одном аккаунте нельзя в принципе. Настройки игрока
 * решают этот вопрос там, где он возникает.
 *
 * ЧТО ГЛАВНЕЕ. Выбор игрока. Переменные окружения работают ТОЛЬКО как
 * запасной вариант — когда строку игрока прочитать не удалось. Обратный
 * порядок (окружение главнее) выглядел бы разумно, но означал бы
 * переключатель, который иногда молча не работает; хуже выключенной
 * настройки только настройка, притворяющаяся включённой.
 */
import { JUDGE_ENABLED } from "./evaluateGrammar.ts";
import { PREFER_DATASET } from "./explainElements.ts";

export interface PlayerPrefs {
  /** Балл выставляет модель. Иначе — поэлементный подсчёт. */
  llmScoring: boolean;
  /** Разбор пишет модель. Иначе — датасет пояснений для пары. */
  llmExplanations: boolean;
  /** Откуда взялись значения — для отладочной панели. */
  source: string;
}

/** Значения, когда о игроке ничего не известно: как настроен сервер. */
export function prefsFromEnv(reason: string): PlayerPrefs {
  return {
    llmScoring: JUDGE_ENABLED,
    llmExplanations: !PREFER_DATASET,
    source: `окружение (${reason})`,
  };
}

/**
 * Читает переключатели игрока.
 *
 * НИКОГДА НЕ БРОСАЕТ. Сбой чтения настроек не имеет права уронить оценку
 * раунда: игрок потеряет попытку из-за строки конфигурации, которая на
 * его ответ не влияет. Не прочиталось — работаем как настроен сервер и
 * честно пишем это в отладку.
 */
export async function loadPlayerPrefs(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  userId: string | null | undefined,
): Promise<PlayerPrefs> {
  if (!userId) return prefsFromEnv("нет игрока в записи");
  try {
    const { data, error } = await supabase
      .from("users")
      .select("llm_scoring_enabled, llm_explanations_enabled")
      .eq("id", userId)
      .maybeSingle();
    if (error) {
      console.error("playerPrefs: не удалось прочитать настройки", error);
      return prefsFromEnv(`ошибка чтения: ${error.message ?? error}`);
    }
    if (!data) return prefsFromEnv("строки игрока нет");
    return {
      llmScoring: data.llm_scoring_enabled === true,
      llmExplanations: data.llm_explanations_enabled === true,
      source: "настройки игрока",
    };
  } catch (e) {
    console.error("playerPrefs: не удалось прочитать настройки", e);
    return prefsFromEnv(`сбой чтения: ${e}`);
  }
}
