import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
  runApp(const BirthdayReminderApp());
}

class BirthdayReminderApp extends StatelessWidget {
  const BirthdayReminderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Birthday Reminder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.pinkAccent,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class Birthday {
  final String id;
  final String name;
  final int month;
  final int day;

  const Birthday({
    required this.id,
    required this.name,
    required this.month,
    required this.day,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'month': month,
        'day': day,
      };

  static Birthday? tryFromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id']?.toString();
    final name = value['name']?.toString().trim();
    final month = value['month'];
    final day = value['day'];
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    if (month is! num || day is! num) return null;
    final m = month.toInt();
    final d = day.toInt();
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    if (!_isValidMonthDay(m, d)) return null;
    return Birthday(id: id, name: name, month: m, day: d);
  }

  static bool _isValidMonthDay(int month, int day) {
    final maxDay = DateTime(2000, month + 1, 0).day;
    return day <= maxDay;
  }

  String get dateString => DateFormat('d MMMM').format(DateTime(2000, month, day));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final FlutterTts _tts = FlutterTts();

  List<Birthday> _birthdays = [];
  bool _isLoading = true;
  String? _startupError;

  static const List<TimeOfDay> _reminderTimes = [
    TimeOfDay(hour: 9, minute: 0),
    TimeOfDay(hour: 14, minute: 0),
    TimeOfDay(hour: 20, minute: 0),
  ];

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      await _initNotifications();
      await _requestPermissions();
      await _initTts();
      await _loadBirthdays();
      await _scheduleAllReminders();
    } catch (e) {
      _startupError = 'App initialize nahi ho paya. Please app dobara open karein.';
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _requestPermissions() async {
    try {
      await Permission.notification.request();
    } catch (_) {}

    try {
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
    } catch (_) {}

    // Exact alarms are optional. If the user does not grant the permission,
    // scheduling falls back to inexact alarms instead of breaking the app.
    try {
      if (await Permission.scheduleExactAlarm.isDenied) {
        await Permission.scheduleExactAlarm.request();
      }
    } catch (_) {}

    try {
      final android = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _notifications.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (response) async {
        final payload = response.payload?.trim();
        if (payload != null && payload.isNotEmpty) {
          await _speak(payload);
        }
      },
    );

    const channel = AndroidNotificationChannel(
      'birthday_channel',
      'Birthday Reminders',
      description: 'Notifications for upcoming birthdays',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('hi-IN');
    } catch (_) {
      try {
        await _tts.setLanguage('en-IN');
      } catch (_) {}
    }
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _speak(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _loadBirthdays() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('birthdays') ?? '[]';

    List<dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      decoded = value is List ? value : <dynamic>[];
    } catch (_) {
      decoded = <dynamic>[];
    }

    final loaded = decoded
        .map(Birthday.tryFromJson)
        .whereType<Birthday>()
        .toList();
    loaded.sort((a, b) => _nextBirthdayDate(a).compareTo(_nextBirthdayDate(b)));

    if (!mounted) return;
    setState(() => _birthdays = loaded);
  }

  Future<void> _saveBirthdays() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'birthdays',
      jsonEncode(_birthdays.map((e) => e.toJson()).toList()),
    );
  }

  DateTime _nextBirthdayDate(Birthday birthday) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    var year = now.year;
    var candidate = _safeBirthdayDate(year, birthday.month, birthday.day);
    if (candidate.isBefore(today)) {
      year++;
      candidate = _safeBirthdayDate(year, birthday.month, birthday.day);
    }
    return candidate;
  }

  // Feb 29 birthdays should become Feb 28 in a non-leap year instead of
  // silently rolling over to March 1 via Dart's DateTime normalization.
  DateTime _safeBirthdayDate(int year, int month, int day) {
    if (month == 2 && day == 29 && !_isLeapYear(year)) {
      return DateTime(year, 2, 28);
    }
    return DateTime(year, month, day);
  }

  bool _isLeapYear(int year) =>
      year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

  DateTime _reminderDay(Birthday birthday) =>
      _nextBirthdayDate(birthday).subtract(const Duration(days: 1));

  Future<void> _scheduleAllReminders() async {
    await _notifications.cancelAll();

    final now = tz.TZDateTime.now(tz.local);
    var notificationId = 1000;

    for (final birthday in _birthdays) {
      final reminderDay = _reminderDay(birthday);
      final today = DateTime(now.year, now.month, now.day);
      final reminderDate = DateTime(
        reminderDay.year,
        reminderDay.month,
        reminderDay.day,
      );
      if (reminderDate.isBefore(today)) continue;

      for (final time in _reminderTimes) {
        final scheduled = tz.TZDateTime(
          tz.local,
          reminderDay.year,
          reminderDay.month,
          reminderDay.day,
          time.hour,
          time.minute,
        );
        if (!scheduled.isAfter(now)) continue;

        final message =
            'Kal ${birthday.name} ka birthday hai! 🎂 Yaad se wish kar dena!';

        try {
          await _scheduleOne(
            id: notificationId++,
            title: '🎂 Birthday Reminder',
            body: message,
            scheduledDate: scheduled,
            payload: message,
          );
        } catch (_) {
          // One failed reminder must not prevent the remaining birthdays from
          // being scheduled.
        }
      }
    }
  }

  Future<void> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required String payload,
  }) async {
    const android = AndroidNotificationDetails(
      'birthday_channel',
      'Birthday Reminders',
      channelDescription: 'Notifications for upcoming birthdays',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.reminder,
    );
    final details = NotificationDetails(android: android);

    try {
      await _notifications.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    } catch (_) {
      await _notifications.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduledDate,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    }
  }

  Future<void> _addOrEditBirthday({Birthday? existing}) async {
    final controller = TextEditingController(text: existing?.name ?? '');
    var selectedMonth = existing?.month ?? DateTime.now().month;
    var selectedDay = existing?.day ?? DateTime.now().day;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final maxDay = DateTime(2000, selectedMonth + 1, 0).day;
          if (selectedDay > maxDay) selectedDay = maxDay;

          return AlertDialog(
            title: Text(existing == null ? 'Naya Birthday Add Karo' : 'Edit Birthday'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Naam',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: selectedMonth,
                          decoration: const InputDecoration(
                            labelText: 'Mahina',
                            border: OutlineInputBorder(),
                          ),
                          items: List.generate(12, (i) {
                            final month = i + 1;
                            return DropdownMenuItem(
                              value: month,
                              child: Text(
                                DateFormat('MMMM').format(DateTime(2000, month)),
                              ),
                            );
                          }),
                          onChanged: (value) {
                            if (value == null) return;
                            setDialogState(() {
                              selectedMonth = value;
                              final newMax = DateTime(2000, value + 1, 0).day;
                              if (selectedDay > newMax) selectedDay = newMax;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: selectedDay,
                          decoration: const InputDecoration(
                            labelText: 'Din',
                            border: OutlineInputBorder(),
                          ),
                          items: List.generate(
                            DateTime(2000, selectedMonth + 1, 0).day,
                            (i) => DropdownMenuItem(
                              value: i + 1,
                              child: Text('${i + 1}'),
                            ),
                          ),
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => selectedDay = value);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (controller.text.trim().isEmpty) return;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    final name = controller.text.trim();
    controller.dispose();

    if (result != true || name.isEmpty || !mounted) return;

    final birthday = Birthday(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      month: selectedMonth,
      day: selectedDay,
    );

    setState(() {
      if (existing == null) {
        _birthdays.add(birthday);
      } else {
        final index = _birthdays.indexWhere((b) => b.id == existing.id);
        if (index != -1) _birthdays[index] = birthday;
      }
      _birthdays.sort((a, b) => _nextBirthdayDate(a).compareTo(_nextBirthdayDate(b)));
    });

    await _saveBirthdays();
    await _scheduleAllReminders();
    await _speak(
      'Birthday save ho gaya. ${birthday.name} ka birthday ${birthday.dateString} ko hai. Ek din pehle reminder milega.',
    );
  }

  Future<void> _deleteBirthday(Birthday birthday) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete?'),
        content: Text('${birthday.name} ko list se hata den?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Nahi'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Haan, Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    setState(() => _birthdays.removeWhere((b) => b.id == birthday.id));
    await _saveBirthdays();
    await _scheduleAllReminders();
  }

  Future<void> _testReminder(Birthday birthday) async {
    final message =
        'Kal ${birthday.name} ka birthday hai! 🎂 Yaad se wish kar dena!';
    await _notifications.show(
      id: 999999,
      title: '🎂 Birthday Reminder (Test)',
      body: message,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'birthday_channel',
          'Birthday Reminders',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
      ),
      payload: message,
    );
    await _speak(message);
  }

  Future<void> _showInfo() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kaise kaam karta hai?'),
        content: const Text(
          '• Birthday add karo (sirf date + naam)\n'
          '• Birthday se 1 din pehle 9 AM, 2 PM aur 8 PM reminder\n'
          '• Notification par tap karne par Hindi voice message\n'
          '• Test Reminder se turant check kar sakte ho\n\n'
          'Exact alarm permission optional hai. Agar permission na mile to app inexact alarm fallback use karega.\n\n'
          'Battery optimization ko Unrestricted rakhne se reminders zyada reliable rahenge.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Samajh gaya'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('🎂 Birthday Reminder'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfo,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_startupError != null)
            MaterialBanner(
              content: Text(_startupError!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _startupError = null),
                  child: const Text('OK'),
                ),
              ],
            ),
          Expanded(
            child: _birthdays.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cake_outlined, size: 80, color: Colors.pink.shade200),
                        const SizedBox(height: 16),
                        const Text(
                          'Abhi koi birthday nahi hai',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Neeche + button se add karo',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _birthdays.length,
                    itemBuilder: (context, index) {
                      final birthday = _birthdays[index];
                      final next = _nextBirthdayDate(birthday);
                      final reminder = _reminderDay(birthday);
                      final today = DateTime.now();
                      final daysLeft = DateTime(next.year, next.month, next.day)
                          .difference(DateTime(today.year, today.month, today.day))
                          .inDays;

                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          leading: CircleAvatar(
                            backgroundColor: Colors.pink.shade100,
                            child: Text(
                              birthday.name.isNotEmpty ? birthday.name[0].toUpperCase() : '?',
                              style: TextStyle(
                                color: Colors.pink.shade800,
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ),
                          title: Text(
                            birthday.name,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text('🎂 ${birthday.dateString}'),
                              Text(
                                daysLeft == 0
                                    ? 'Aaj birthday hai! 🎉'
                                    : daysLeft == 1
                                        ? 'Kal birthday hai!'
                                        : '$daysLeft din baad',
                                style: TextStyle(
                                  color: daysLeft <= 1 ? Colors.red : Colors.grey.shade600,
                                  fontWeight: daysLeft <= 1 ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              Text(
                                'Reminder: ${DateFormat('d MMM').format(reminder)} (3 baar)',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                              ),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              switch (value) {
                                case 'test':
                                  _testReminder(birthday);
                                  break;
                                case 'edit':
                                  _addOrEditBirthday(existing: birthday);
                                  break;
                                case 'delete':
                                  _deleteBirthday(birthday);
                                  break;
                                case 'card':
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => BirthdayCardPage(birthday: birthday),
                                    ),
                                  );
                                  break;
                              }
                            },
                            itemBuilder: (ctx) => const [
                              PopupMenuItem(
                                value: 'test',
                                child: Row(
                                  children: [
                                    Icon(Icons.volume_up, size: 20),
                                    SizedBox(width: 8),
                                    Text('Test Reminder'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'edit',
                                child: Row(
                                  children: [
                                    Icon(Icons.edit, size: 20),
                                    SizedBox(width: 8),
                                    Text('Edit'),
                                  ],
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'card',
                                child: Row(
                                  children: [
                                    Icon(Icons.card_giftcard, size: 20),
                                    SizedBox(width: 8),
                                    Text('Create Birthday Card'),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete, color: Colors.red, size: 20),
                                    SizedBox(width: 8),
                                    Text('Delete', style: TextStyle(color: Colors.red)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOrEditBirthday,
        icon: const Icon(Icons.add),
        label: const Text('Add Birthday'),
        backgroundColor: Colors.pinkAccent,
        foregroundColor: Colors.white,
      ),
    );
  }
}

class BirthdayCardPage extends StatefulWidget {
  final Birthday birthday;
  const BirthdayCardPage({super.key, required this.birthday});

  @override
  State<BirthdayCardPage> createState() => _BirthdayCardPageState();
}

class _BirthdayCardPageState extends State<BirthdayCardPage> {
  final GlobalKey _cardKey = GlobalKey();
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _schoolController = TextEditingController();
  final TextEditingController _classController = TextEditingController();
  final TextEditingController _messageController = TextEditingController(
    text: 'Wishing you a very Happy Birthday! 🎂🎉',
  );
  XFile? _photo;
  bool _sharing = false;
  int _templateIndex = 0;

  static const _templateNames = <String>[
    'Kids Pop',
    'Rainbow',
    'Balloons',
    'Royal',
    'School Star',
    'Cute Doodle',
  ];

  @override
  void dispose() {
    _schoolController.dispose();
    _classController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1400,
        maxHeight: 1400,
        imageQuality: 88,
      );
      if (picked != null && mounted) {
        setState(() => _photo = picked);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Photo select nahi ho paya: $e')),
      );
    }
  }

  Future<void> _shareCard() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final boundary = _cardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Card preview ready nahi hai');

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('Card image create nahi hua');
      final Uint8List bytes = byteData.buffer.asUint8List();

      final dir = await getTemporaryDirectory();
      final safeName = widget.birthday.name
          .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
          .trim();
      final file = File('${dir.path}/birthday_card_${safeName.isEmpty ? 'card' : safeName}.png');
      await file.writeAsBytes(bytes, flush: true);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: '🎂 ${widget.birthday.name} ko Happy Birthday! 🎉',
        subject: 'Birthday Card',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Card share nahi ho paya: $e')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Widget _cardPreview() {
    final school = _schoolController.text.trim();
    final className = _classController.text.trim();
    final message = _messageController.text.trim().isEmpty
        ? 'Wishing you a very Happy Birthday! 🎂🎉'
        : _messageController.text.trim();

    final schemes = <Map<String, dynamic>>[
      {
        'bg': const [Color(0xFFFFF0F6), Color(0xFFFFD6E7), Color(0xFFFFF7FB)],
        'accent': const Color(0xFFD81B60),
        'text': const Color(0xFF4A2A36),
        'icon': '🎂',
        'label': 'HAPPY BIRTHDAY',
        'footer': '🎈',
      },
      {
        'bg': const [Color(0xFFE8F8FF), Color(0xFFD9F7E8), Color(0xFFFFF7D6)],
        'accent': const Color(0xFF00897B),
        'text': const Color(0xFF21434A),
        'icon': '🌈',
        'label': 'BIRTHDAY STAR',
        'footer': '✨',
      },
      {
        'bg': const [Color(0xFFFFE9D6), Color(0xFFFFF5E8), Color(0xFFFFDCEB)],
        'accent': const Color(0xFFEF6C00),
        'text': const Color(0xFF5D4037),
        'icon': '🎈',
        'label': 'HAPPY BIRTHDAY',
        'footer': '🎉',
      },
      {
        'bg': const [Color(0xFF17142B), Color(0xFF33255B), Color(0xFF5D3A88)],
        'accent': const Color(0xFFFFD54F),
        'text': Colors.white,
        'icon': '👑',
        'label': 'BIRTHDAY ROYALTY',
        'footer': '⭐',
      },
      {
        'bg': const [Color(0xFFEAF4FF), Color(0xFFF7FBFF), Color(0xFFE4F0FF)],
        'accent': const Color(0xFF1565C0),
        'text': const Color(0xFF263238),
        'icon': '⭐',
        'label': 'OUR BIRTHDAY STAR',
        'footer': '🎓',
      },
      {
        'bg': const [Color(0xFFFFF4C2), Color(0xFFFFE4F0), Color(0xFFE7F6FF)],
        'accent': const Color(0xFF7B1FA2),
        'text': const Color(0xFF49314F),
        'icon': '🦄',
        'label': 'HAPPY BIRTHDAY',
        'footer': '💖',
      },
    ];
    final scheme = schemes[_templateIndex];
    final dark = _templateIndex == 3;
    final bg = scheme['bg'] as List<Color>;
    final accent = scheme['accent'] as Color;
    final textColor = scheme['text'] as Color;

    return RepaintBoundary(
      key: _cardKey,
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: bg,
          ),
          border: Border.all(color: accent, width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 7)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(scheme['icon'] as String, style: const TextStyle(fontSize: 44)),
            const SizedBox(height: 4),
            Text(
              scheme['label'] as String,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
                color: accent,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: 154,
              height: 154,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark ? const Color(0xFF201B3A) : Colors.white,
                border: Border.all(color: accent, width: 3),
              ),
              child: ClipOval(
                child: _photo == null
                    ? Icon(Icons.person, size: 82, color: accent)
                    : Image.file(File(_photo!.path), fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              widget.birthday.name,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: accent),
            ),
            if (className.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                'Class: $className',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: textColor),
              ),
            ],
            if (school.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                school,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, height: 1.35, color: textColor),
            ),
            const SizedBox(height: 14),
            Text(
              '${scheme['footer']}  ${widget.birthday.dateString}  ${scheme['footer']}',
              style: TextStyle(fontWeight: FontWeight.bold, color: accent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _templatePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Card Design Choose Karo',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _templateNames.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              return ChoiceChip(
                label: Text(_templateNames[index]),
                selected: _templateIndex == index,
                onSelected: (_) => setState(() => _templateIndex = index),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Birthday Card'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _cardPreview(),
              const SizedBox(height: 16),
              _templatePicker(),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _pickPhoto,
                icon: const Icon(Icons.photo_library),
                label: Text(_photo == null ? 'Bacche ka Photo Add Karo' : 'Photo Change Karo'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _classController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Class (optional)',
                  prefixIcon: Icon(Icons.school),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _schoolController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'School Name (optional)',
                  prefixIcon: Icon(Icons.apartment),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _messageController,
                onChanged: (_) => setState(() {}),
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Birthday Message',
                  prefixIcon: Icon(Icons.message),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _sharing ? null : _shareCard,
                  icon: _sharing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.share),
                  label: Text(_sharing ? 'Card bana raha hoon...' : 'Create & Share Card'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Photo phone ki gallery se select hoga. Card image banakar WhatsApp ya kisi bhi sharing app me bhej sakte ho.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

