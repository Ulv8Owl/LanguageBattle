import 'package:supabase_flutter/supabase_flutter.dart';

/// Single shared handle to the Supabase client. Every feature talks to
/// Supabase through this — never instantiate a second client.
SupabaseClient get supabase => Supabase.instance.client;

String get currentUserId {
  final id = supabase.auth.currentUser?.id;
  if (id == null) {
    throw StateError('No authenticated user.');
  }
  return id;
}
