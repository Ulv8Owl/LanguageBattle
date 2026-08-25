class MatchData {
  final String id;
  final String? playerAId;
  final String? playerBId;
  final String gameMode; // 'sparring' | 'native_duel'
  final String? languagePair;
  final String status; // 'matchmaking' | 'in_progress' | 'completed' | 'abandoned'
  final String? winnerId;
  final DateTime createdAt;

  const MatchData({
    required this.id,
    required this.playerAId,
    required this.playerBId,
    required this.gameMode,
    required this.languagePair,
    required this.status,
    required this.winnerId,
    required this.createdAt,
  });

  factory MatchData.fromRow(Map<String, dynamic> row) {
    return MatchData(
      id: row['id'] as String,
      playerAId: row['player_a_id'] as String?,
      playerBId: row['player_b_id'] as String?,
      gameMode: row['game_mode'] as String,
      languagePair: row['language_pair'] as String?,
      status: row['status'] as String,
      winnerId: row['winner_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  bool get isDuel => gameMode == 'native_duel';

  /// Slots each player must fill per round, in recording order.
  List<String> get requiredSlots => isDuel ? const ['native', 'target'] : const ['target'];

  /// The language a given player should record for a given slot, based on
  /// the `language_pair` convention documented in supabase/README.md:
  /// sparring -> language_pair is just the shared target language;
  /// native_duel -> `"nativeOfA-nativeOfB"`.
  String languageForSlot(String userId, String slot) {
    if (!isDuel) return languagePair ?? 'en';
    final parts = (languagePair ?? 'en-en').split('-');
    final nativeA = parts.isNotEmpty ? parts[0] : 'en';
    final nativeB = parts.length > 1 ? parts[1] : 'en';
    final isPlayerA = userId == playerAId;
    final myNative = isPlayerA ? nativeA : nativeB;
    final myTarget = isPlayerA ? nativeB : nativeA;
    return slot == 'native' ? myNative : myTarget;
  }
}

class RoundData {
  final String id;
  final String matchId;
  final int roundNumber;
  final String? generatedPhrase;

  /// Индекс фразы в PhraseBank.phrases — нужен клиенту, чтобы не повторять
  /// уже сыгранные фразы в пределах одного матча (см. battle_screen.dart).
  final int? phraseIndex;
  final DateTime createdAt;

  const RoundData({
    required this.id,
    required this.matchId,
    required this.roundNumber,
    required this.generatedPhrase,
    required this.phraseIndex,
    required this.createdAt,
  });

  factory RoundData.fromRow(Map<String, dynamic> row) {
    return RoundData(
      id: row['id'] as String,
      matchId: row['match_id'] as String,
      roundNumber: row['round_number'] as int,
      generatedPhrase: row['generated_phrase'] as String?,
      phraseIndex: row['phrase_index'] as int?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

class VoiceRecordingData {
  final String id;
  final String roundId;
  final String userId;
  final String recordingSlot;
  final String? languageCode;
  final String audioStoragePath;
  final DateTime createdAt;

  const VoiceRecordingData({
    required this.id,
    required this.roundId,
    required this.userId,
    required this.recordingSlot,
    required this.languageCode,
    required this.audioStoragePath,
    required this.createdAt,
  });

  factory VoiceRecordingData.fromRow(Map<String, dynamic> row) {
    return VoiceRecordingData(
      id: row['id'] as String,
      roundId: row['round_id'] as String,
      userId: row['user_id'] as String,
      recordingSlot: row['recording_slot'] as String,
      languageCode: row['language_code'] as String?,
      audioStoragePath: row['audio_storage_path'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

class RoundScoreData {
  final String id;
  final String roundId;
  final String userId;
  final int? score;
  final String? aiFeedback;

  const RoundScoreData({
    required this.id,
    required this.roundId,
    required this.userId,
    required this.score,
    required this.aiFeedback,
  });

  factory RoundScoreData.fromRow(Map<String, dynamic> row) {
    return RoundScoreData(
      id: row['id'] as String,
      roundId: row['round_id'] as String,
      userId: row['user_id'] as String,
      score: row['score'] as int?,
      aiFeedback: row['ai_feedback'] as String?,
    );
  }
}
