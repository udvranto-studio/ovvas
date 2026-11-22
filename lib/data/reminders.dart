import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../domain/dates.dart';
import '../domain/habit.dart';
import '../domain/stats.dart';
import '../l10n/app_localizations.dart';
import 'habit_store.dart';
import 'settings_controller.dart';

/// When the daily summary is shown.
const summaryTime = ReminderTime(21, 0);

/// iOS keeps only this many pending notifications.
const _maxPending = 64;

/// One notification to schedule. [repeat] null means it fires once.
class PlannedReminder {
  const PlannedReminder(this.title, this.body, this.at, {this.repeat});

  final String title;
  final String body;
  final DateTime at;
  final DateTimeComponents? repeat;

  @override
  String toString() => '$title|$body|$at|$repeat';
}

/// Every notification the app should have scheduled right now: habit
/// reminders, the daily summary and the weekly report. Times inside quiet
/// hours are left out.
List<PlannedReminder> planReminders(HabitStore store, SettingsController settings, AppLocalizations l) {
  final now = store.now();
  final today = store.today;
  final stats = store.stats;
  bool quiet(ReminderTime t) => isQuiet(t, settings.quietStart, settings.quietEnd);
  final out = <PlannedReminder>[];

  if (settings.dailySummary && !quiet(summaryTime)) {
    final at = DateTime(today.year, today.month, today.day, summaryTime.hour, summaryTime.minute);
    final due = [
      for (final h in store.habitsOn(today))
        if (stats.status(h, today) case final s when s != DayStatus.notScheduled && s != DayStatus.skipped) s,
    ];
    // shortcut: the counts are taken at the last change today, and nothing is
    // sent on days the app is not opened. Upgrade with a background task.
    if (at.isAfter(now) && due.isNotEmpty) {
      out.add(PlannedReminder(l.dailySummary, l.dailySummaryBody(due.where((s) => s == DayStatus.done).length, due.length), at));
    }
  }

  if (settings.weeklyReport && !quiet(settings.defaultReminder)) {
    final weekStart = startOfWeek(today, settings.firstWeekday);
    final next = addDays(weekStart, 7);
    // shortcut: the rate is taken at the last change this week.
    final rate = stats.summarize(store.habits, weekStart, addDays(next, -1)).rate;
    if (rate != null) {
      final hardest = stats.hardestWeekday(store.habits, addDays(today, -55), today);
      final insight = hardest == null
          ? l.insightKeepGoing
          : l.insightHardestDay(DateFormat.EEEE(l.localeName).format(DateTime(2024, 1, hardest)));
      final t = settings.defaultReminder;
      out.add(PlannedReminder(l.weeklyReport, '${l.weeklyReportBody((rate * 100).round())} $insight',
          DateTime(next.year, next.month, next.day, t.hour, t.minute)));
    }
  }

  for (final h in store.habits) {
    // shortcut: repeating reminders don't know the start and end dates. A
    // habit is scheduled once the app runs on or after its start day, and
    // keeps reminding after its end date until the app is opened again.
    if (h.startDate.isAfter(today) || (h.endDate != null && h.endDate!.isBefore(today))) continue;
    for (final t in h.reminders) {
      if (quiet(t)) continue;
      if (h.repeat == RepeatKind.weekdays) {
        for (final wd in h.weekdays) {
          out.add(PlannedReminder(h.name, l.reminderBody, nextAt(now, t, weekday: wd),
              repeat: DateTimeComponents.dayOfWeekAndTime));
        }
      } else {
        out.add(PlannedReminder(h.name, l.reminderBody, nextAt(now, t), repeat: DateTimeComponents.time));
      }
    }
  }
  // shortcut: past 64, the last habit reminders are dropped (iOS limit).
  return out.take(_maxPending).toList();
}

/// Whether [t] falls in quiet hours from [start] to [end], which may cross midnight.
bool isQuiet(ReminderTime t, ReminderTime start, ReminderTime end) {
  final m = t.minutesOfDay, s = start.minutesOfDay, e = end.minutesOfDay;
  if (s == e) return false;
  return s < e ? m >= s && m < e : m >= s || m < e;
}

/// The next time after [now] at [t], on [weekday] when given.
DateTime nextAt(DateTime now, ReminderTime t, {int? weekday}) {
  var d = DateTime(now.year, now.month, now.day, t.hour, t.minute);
  while (!d.isAfter(now) || (weekday != null && d.weekday != weekday)) {
    d = DateTime(d.year, d.month, d.day + 1, t.hour, t.minute);
  }
  return d;
}

/// Keeps the phone's scheduled notifications in step with habits and settings.
class ReminderScheduler {
  ReminderScheduler(this._store, this._settings);

  final HabitStore _store;
  final SettingsController _settings;
  final _plugin = FlutterLocalNotificationsPlugin();
  Timer? _debounce;
  Future<void> _applying = Future.value();
  String? _applied;
  bool _asked = false;

  /// shortcut: Android and iOS only, the platforms the app ships on.
  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> start() async {
    if (!supported) return;
    try {
      await initializeDateFormatting();
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
    } catch (e, s) {
      debugPrint('Reminders unavailable: $e\n$s');
      return;
    }
    _store.addListener(_changed);
    _settings.addListener(_changed);
    _changed();
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () {
      _applying = _applying.then((_) => _apply()).catchError((Object e, StackTrace s) {
        debugPrint('Scheduling reminders failed: $e\n$s');
      });
    });
  }

  Future<void> _apply() async {
    final l = lookupAppLocalizations(_settings.locale);
    final plan = planReminders(_store, _settings, l);
    final key = plan.join('\n');
    if (key == _applied) return;
    if (plan.isNotEmpty && !_asked) {
      _asked = true;
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
    }
    await _plugin.cancelAll();
    final details = NotificationDetails(
      android: AndroidNotificationDetails('reminders', l.reminders),
      iOS: const DarwinNotificationDetails(),
    );
    for (final (i, r) in plan.indexed) {
      await _plugin.zonedSchedule(
        id: i,
        title: r.title,
        body: r.body,
        scheduledDate: tz.TZDateTime(tz.local, r.at.year, r.at.month, r.at.day, r.at.hour, r.at.minute),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: r.repeat,
      );
    }
    _applied = key;
  }
}
