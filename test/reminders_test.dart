import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:ovvas/data/habit_store.dart';
import 'package:ovvas/data/reminders.dart';
import 'package:ovvas/data/settings_controller.dart';
import 'package:ovvas/domain/habit.dart';
import 'package:ovvas/l10n/app_localizations.dart';

void main() {
  // Wednesday 21 October 2026, 08:00.
  final now = DateTime(2026, 10, 21, 8);
  final l = lookupAppLocalizations(const Locale('en'));
  setUpAll(initializeDateFormatting);

  Habit habit(String id, {RepeatKind repeat = RepeatKind.everyDay, Set<int> weekdays = Habit.allWeekdays}) => Habit(
        id: id,
        name: id,
        iconIndex: 0,
        colorIndex: 0,
        repeat: repeat,
        weekdays: weekdays,
        reminders: const [ReminderTime(9, 0), ReminderTime(23, 0)],
        startDate: DateTime(2026, 10, 1),
      );

  test('habit reminders repeat, skip quiet hours, and expand chosen weekdays', () {
    final store = HabitStore(clock: () => now)
      ..addHabit(habit('daily'))
      ..addHabit(habit('mon-fri', repeat: RepeatKind.weekdays, weekdays: {1, 5}));
    final settings = SettingsController()
      ..dailySummary = false
      ..weeklyReport = false;

    final plan = planReminders(store, settings, l);

    // 23:00 is inside the default quiet hours (22:00–07:00).
    expect(plan.map((r) => (r.title, r.at, r.repeat)), [
      ('daily', DateTime(2026, 10, 21, 9), DateTimeComponents.time),
      ('mon-fri', DateTime(2026, 10, 26, 9), DateTimeComponents.dayOfWeekAndTime),
      ('mon-fri', DateTime(2026, 10, 23, 9), DateTimeComponents.dayOfWeekAndTime),
    ]);
  });

  test('daily summary counts today, weekly report fires at the next week start', () {
    final store = HabitStore(clock: () => now)
      ..addHabit(habit('a').copyWith(reminders: const []))
      ..addHabit(habit('b').copyWith(reminders: const []));
    store.toggle(store.habits.first, now);
    final settings = SettingsController()
      ..dailySummary = true
      ..weeklyReport = true;

    final plan = planReminders(store, settings, l);

    expect(plan[0].body, '1 of 2 habits done today');
    expect(plan[0].at, DateTime(2026, 10, 21, 21));
    expect(plan[1].at, DateTime(2026, 10, 26, 9), reason: 'Monday at the default reminder time');
    expect(plan.length, 2);
  });

  test('quiet hours can cross midnight', () {
    const start = ReminderTime(22, 0), end = ReminderTime(7, 0);
    expect(isQuiet(const ReminderTime(23, 30), start, end), isTrue);
    expect(isQuiet(const ReminderTime(6, 59), start, end), isTrue);
    expect(isQuiet(const ReminderTime(7, 0), start, end), isFalse);
    expect(isQuiet(const ReminderTime(12, 0), const ReminderTime(13, 0), const ReminderTime(14, 0)), isFalse);
  });
}
