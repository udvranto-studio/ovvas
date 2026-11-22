import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovvas/data/local/database.dart';
import 'package:ovvas/data/local/records.dart';
import 'package:ovvas/data/sync/supabase_sync.dart';
import 'package:ovvas/domain/habit.dart';

/// Downloaded rows replace local ones only when they are newer.
void main() {
  late AppDatabase db;
  late SupabaseCloudSync sync;
  final day = DateTime(2026, 10, 21);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // Merging only touches the local database, so no Supabase client is needed.
    sync = SupabaseCloudSync(db, redirectUrl: 'test://');
    final h = Habit(id: 'h', name: 'Local', iconIndex: 0, colorIndex: 0, startDate: day);
    await db.into(db.habits).insert(habitToRow(h, 200));
    await db.into(db.entries).insert(entryToRow('h', day, const DayEntry(value: 1), 200));
  });
  tearDown(() => db.close());

  Future<HabitRow> habit() => db.select(db.habits).getSingle();
  Future<List<EntryRow>> entries() => db.select(db.entries).get();

  test('an older cloud habit is ignored, a newer one replaces the local copy', () async {
    final local = await habit();

    expect(await sync.mergeHabits([habitRowToCloud(local.copyWith(name: 'Old', updatedAt: 100), 'u')]), isFalse);
    expect((await habit()).name, 'Local');
    expect(await sync.mergeHabits([habitRowToCloud(local.copyWith(name: 'Same', updatedAt: 200), 'u')]), isFalse,
        reason: 'a tie keeps the local copy');

    expect(await sync.mergeHabits([habitRowToCloud(local.copyWith(name: 'New', updatedAt: 300), 'u')]), isTrue);
    final merged = await habit();
    expect((merged.name, merged.updatedAt, merged.dirty), ('New', 300, false));
  });

  test('a newer cloud deletion removes the habit\'s check-ins', () async {
    final local = await habit();
    await sync.mergeHabits([habitRowToCloud(local.copyWith(deleted: true, updatedAt: 300), 'u')]);
    expect((await habit()).deleted, isTrue);
    expect(await entries(), isEmpty);
  });

  test('check-ins merge by habit and day, newest wins', () async {
    final local = (await entries()).single;

    await sync.mergeEntries([entryRowToCloud(local.copyWith(value: 9, updatedAt: 100), 'u')]);
    expect((await entries()).single.value, 1);

    await sync.mergeEntries([
      entryRowToCloud(local.copyWith(value: 5, updatedAt: 300), 'u'),
      entryRowToCloud(local.copyWith(day: '2026-10-22', value: 2, updatedAt: 300), 'u'),
    ]);
    expect({for (final e in await entries()) e.day: (e.value, e.dirty)}, {
      '2026-10-21': (5, false),
      '2026-10-22': (2, false),
    });
  });
}
