// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Native Windows launcher for PS5PCEM.
//!
//! The interface deliberately uses only Win32/GDI so the emulator keeps its
//! zero-dependency build. Settings are persisted next to the executable and
//! passed to game-run through its small environment contract.

const std = @import("std");
const input = @import("input");
const builtin = @import("builtin");

comptime {
    // The interface contains a fair amount of Cyrillic text converted to
    // UTF-16 at compile time.
    @setEvalBranchQuota(20_000);
}

const github_url = "https://github.com/iStark/PS5PCEM";
const boosty_url = "https://boosty.to/ps5pcem";
const window_width = 1180;
const window_height = 760;
const sidebar_width = 222;

const Page = enum { library, input, saves, settings };
const InputMode = enum(u8) { controller = 0, keyboard = 1, hybrid = 2 };
const Language = enum(u8) { english = 0, russian = 1, german = 2, french = 3 };

const Phrase = enum {
    nav_library,
    nav_input,
    nav_settings,
    project,
    support_boosty,
    library_heading,
    library_subtitle,
    folder_label,
    folder_prompt,
    folder_empty,
    choose_folder,
    legal_notice,
    sound,
    enabled,
    disabled,
    sound_timing,
    controls,
    gamepad,
    keyboard_dualsense,
    gamepad_keyboard,
    controller_description,
    keyboard_description,
    hybrid_description,
    configure_layout,
    core_ready,
    launch_game,
    input_heading,
    input_subtitle,
    keyboard,
    hybrid,
    xinput_slot,
    wasd_mapping,
    both_sources,
    keyboard_layout,
    mapping_hint,
    settings_heading,
    settings_subtitle,
    language,
    sound_output,
    sound_output_description,
    fps_counter,
    fps_counter_description,
    compatibility,
    compatibility_text,
    author,
    browse_dialog,
    pad_searching,
    nav_saves,
    saves_heading,
    saves_subtitle,
    saves_empty,
    saves_open_folder,
    pad_test,
    pad_test_unavailable,
    pad_absent,
    status_layout_saved,
    status_press_key,
    status_input_saved,
    status_controller_saved,
    status_sound_on,
    status_sound_off,
    status_fps_on,
    status_fps_off,
    status_folder_selected,
    status_choose_folder,
    status_eboot_missing,
    status_runner_missing,
    status_launch_failed,
    status_launched,
    status_game_removed,
};

const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

const mapping_names = [_][]const u8{
    "Cross",   "Circle",    "Square",   "Triangle",    "L1",         "L2",         "R1", "R2",
    "Options", "Touch pad", "D-pad up", "D-pad right", "D-pad down", "D-pad left",
};
const mapping_defaults = [_]u8{ 0x20, 'E', 'F', 'Q', 0x10, 0x11, 'R', 'T', 0x0d, 0x09, 0x26, 0x27, 0x28, 0x25 };

var current_page: Page = .library;
var input_mode: InputMode = .hybrid;
var language: Language = .english;
var controller_index: u8 = 0;
/// What the HID scan last saw. Polled on a timer rather than during paint so
/// the answer does not depend on how often the window happens to redraw.
var pad_presence: input.hid.Presence = .{};
const pad_timer_id: usize = 1;
const pad_test_timer_id: usize = 2;
/// How often the self-test advances. Fine enough that the colours read as a
/// sweep rather than a slideshow.
const pad_test_tick_ms: u32 = 40;
var current_window: Win32.Window = null;
var sound_enabled = true;
var show_fps = false;
var mapping = mapping_defaults;
var capture_mapping: ?usize = null;
var game_folder: [1024]u16 = [_]u16{0} ** 1024;
var game_folder_length: usize = 0;
const maximum_recent_games = 8;
const RecentGame = struct {
    folder: [1024]u16 = @splat(0),
    folder_length: usize = 0,
    title: [128]u16 = @splat(0),
    title_length: usize = 0,
    identifier: [32]u16 = @splat(0),
    identifier_length: usize = 0,
    icon: Win32.Bitmap = null,
};
var recent_games: [maximum_recent_games]RecentGame = @splat(.{});
var recent_game_count: usize = 0;
var hovered_recent_game: ?usize = null;
var hovered_recent_remove = false;
var tracking_mouse_leave = false;
/// The product code the selected title publishes about itself. Saves are keyed
/// by it, so without one there is no directory to show.
var title_identifier: [32]u16 = @splat(0);
var title_identifier_length: usize = 0;
var status_text: [256]u16 = [_]u16{0} ** 256;
var status_length: usize = 0;
var status_error = false;
var ini_path: [1024]u16 = [_]u16{0} ** 1024;
var ini_path_length: usize = 0;
var regular_font: Win32.Font = null;
var medium_font: Win32.Font = null;
var title_font: Win32.Font = null;
var small_font: Win32.Font = null;
var application_icon: Win32.Icon = null;
var gdiplus_ready = false;

fn tr(phrase: Phrase) []const u8 {
    return switch (language) {
        .english => switch (phrase) {
            .nav_library => "Library",
            .nav_input => "Controls",
            .nav_settings => "Settings",
            .project => "PROJECT",
            .support_boosty => "Support on Boosty  ↗",
            .library_heading => "Game library",
            .library_subtitle => "Previously selected games stay here with their local artwork",
            .folder_label => "GAME FOLDER",
            .folder_prompt => "Select the directory that contains eboot.bin",
            .folder_empty => "No folder selected",
            .choose_folder => "Choose folder",
            .legal_notice => "Game content is not included · use only files you are legally allowed to access",
            .sound => "SOUND",
            .enabled => "Enabled",
            .disabled => "Disabled",
            .sound_timing => "AudioOut keeps game timing even when host output is disabled",
            .controls => "CONTROLS",
            .gamepad => "Gamepad",
            .keyboard_dualsense => "Keyboard as DualSense",
            .gamepad_keyboard => "Gamepad + keyboard",
            .controller_description => "XInput controller · standard layout",
            .keyboard_description => "WASD, arrow keys and custom bindings",
            .hybrid_description => "Both input sources work at the same time",
            .configure_layout => "Configure bindings  →",
            .core_ready => "Core ready · Vulkan VideoOut · Windows x86-64",
            .launch_game => "Launch game  ▶",
            .input_heading => "Controls",
            .input_subtitle => "Choose an input source and map keyboard keys to DualSense buttons",
            .keyboard => "Keyboard",
            .hybrid => "Hybrid",
            .xinput_slot => "XInput slot",
            .wasd_mapping => "WASD + bindings",
            .both_sources => "Gamepad + keyboard",
            .keyboard_layout => "KEYBOARD BINDINGS",
            .mapping_hint => "Click a row and press a key. WASD always controls the left stick; Alt + arrows controls the right stick.",
            .settings_heading => "Settings",
            .settings_subtitle => "Launch preferences and project information",
            .language => "LANGUAGE",
            .sound_output => "Sound output",
            .sound_output_description => "Disabling sound does not affect AudioOut timing",
            .fps_counter => "FPS counter",
            .fps_counter_description => "Show the measured frame rate in the game window title",
            .compatibility => "Compatibility",
            .compatibility_text => "PS5PCEM is at an early stage. Not every title boots yet; advanced DualSense features, native PS5 keyboard/mouse and controller-to-keyboard conversion still need more HLE support.",
            .author => "Author: Artur Strazewicz · GitHub: iStark/PS5PCEM",
            .browse_dialog => "Choose the folder containing a decrypted PS5 game",
            .nav_saves => "Saves",
            .saves_heading => "Saved games",
            .saves_subtitle => "All local save slots, grouped by title ID and kept beside the emulator.",
            .saves_empty => "No local saved games were found",
            .saves_open_folder => "Open folder",
            .pad_test => "Test",
            .pad_test_unavailable => "Controller cannot be driven",
            .pad_searching => "Searching for a controller",
            .pad_absent => "No controller detected",
            .status_layout_saved => "Keyboard bindings saved",
            .status_press_key => "Press a new key · Esc to cancel",
            .status_input_saved => "Input profile saved",
            .status_controller_saved => "Controller slot saved",
            .status_sound_on => "Sound enabled",
            .status_sound_off => "Sound disabled",
            .status_fps_on => "FPS counter enabled",
            .status_fps_off => "FPS counter disabled",
            .status_folder_selected => "Folder selected · ready to launch",
            .status_choose_folder => "Choose a game folder first",
            .status_eboot_missing => "eboot.bin was not found in the selected folder or decrypted subfolder",
            .status_runner_missing => "game-run.exe was not found · run zig build first",
            .status_launch_failed => "Could not start game-run.exe",
            .status_launched => "Game launched in a separate process",
            .status_game_removed => "Game removed from the library",
        },
        .russian => switch (phrase) {
            .nav_library => "Библиотека",
            .nav_input => "Управление",
            .nav_settings => "Настройки",
            .project => "ПРОЕКТ",
            .support_boosty => "Поддержать на Boosty  ↗",
            .library_heading => "Игровая библиотека",
            .library_subtitle => "Ранее выбранные игры остаются здесь вместе с локальными обложками",
            .folder_label => "ПАПКА С ИГРОЙ",
            .folder_prompt => "Укажите каталог, в котором находится eboot.bin",
            .folder_empty => "Папка пока не выбрана",
            .choose_folder => "Выбрать папку",
            .legal_notice => "Контент игр не входит в проект · используйте только законно полученные файлы",
            .sound => "ЗВУК",
            .enabled => "Включён",
            .disabled => "Выключен",
            .sound_timing => "AudioOut сохраняет игровой тайминг даже без вывода",
            .controls => "УПРАВЛЕНИЕ",
            .gamepad => "Геймпад",
            .keyboard_dualsense => "Клавиатура как DualSense",
            .gamepad_keyboard => "Геймпад + клавиатура",
            .controller_description => "XInput-контроллер · стандартная раскладка",
            .keyboard_description => "WASD, стрелки и настраиваемые клавиши",
            .hybrid_description => "Оба источника работают одновременно",
            .configure_layout => "Настроить раскладку  →",
            .core_ready => "Ядро готово · Vulkan VideoOut · Windows x86-64",
            .launch_game => "Запустить игру  ▶",
            .input_heading => "Управление",
            .input_subtitle => "Выберите источник и назначьте клавиши на кнопки DualSense",
            .keyboard => "Клавиатура",
            .hybrid => "Гибридный",
            .xinput_slot => "Слот XInput",
            .wasd_mapping => "WASD + назначение",
            .both_sources => "Геймпад + клавиатура",
            .keyboard_layout => "РАСКЛАДКА КЛАВИАТУРЫ",
            .mapping_hint => "Кликните по строке и нажмите клавишу. WASD управляет левым стиком; Alt + стрелки — правым.",
            .settings_heading => "Настройки",
            .settings_subtitle => "Базовые параметры запуска и сведения о проекте",
            .language => "ЯЗЫК",
            .sound_output => "Вывод звука",
            .sound_output_description => "Отключение не нарушает тайминг AudioOut",
            .fps_counter => "Счётчик FPS",
            .fps_counter_description => "Показывать частоту кадров в заголовке окна игры",
            .compatibility => "Совместимость",
            .compatibility_text => "PS5PCEM находится на ранней стадии. Не все игры загружаются; функции DualSense, нативные PS5-клавиатура/мышь и преобразование геймпада в клавиши требуют дальнейшей HLE-поддержки.",
            .author => "Автор: Artur Strazewicz · GitHub: iStark/PS5PCEM",
            .browse_dialog => "Выберите папку с расшифрованной игрой PS5",
            .nav_saves => "Сохранения",
            .saves_heading => "Сохранения",
            .saves_subtitle => "Все локальные сохранения по Title ID, хранящиеся рядом с эмулятором.",
            .saves_empty => "Локальные сохранения не найдены",
            .saves_open_folder => "Открыть папку",
            .pad_test => "Тест",
            .pad_test_unavailable => "Контроллер недоступен для управления",
            .pad_searching => "Поиск контроллера",
            .pad_absent => "Контроллер не найден",
            .status_layout_saved => "Раскладка сохранена",
            .status_press_key => "Нажмите новую клавишу · Esc — отмена",
            .status_input_saved => "Профиль ввода сохранён",
            .status_controller_saved => "Слот контроллера сохранён",
            .status_sound_on => "Звук включён",
            .status_sound_off => "Звук выключен",
            .status_fps_on => "Счётчик FPS включён",
            .status_fps_off => "Счётчик FPS выключен",
            .status_folder_selected => "Папка выбрана · готово к запуску",
            .status_choose_folder => "Сначала выберите папку с игрой",
            .status_eboot_missing => "В выбранной папке не найден eboot.bin (проверены корень и decrypted)",
            .status_runner_missing => "Не найден game-run.exe · сначала выполните zig build",
            .status_launch_failed => "Не удалось запустить game-run.exe",
            .status_launched => "Игра запущена в отдельном процессе",
            .status_game_removed => "Игра удалена из библиотеки",
        },
        .german => switch (phrase) {
            .nav_library => "Bibliothek",
            .nav_input => "Steuerung",
            .nav_settings => "Einstellungen",
            .project => "PROJEKT",
            .support_boosty => "Auf Boosty unterstützen  ↗",
            .library_heading => "Spielebibliothek",
            .library_subtitle => "Früher ausgewählte Spiele bleiben mit lokalem Artwork in der Bibliothek",
            .folder_label => "SPIELORDNER",
            .folder_prompt => "Wähle das Verzeichnis mit eboot.bin",
            .folder_empty => "Noch kein Ordner ausgewählt",
            .choose_folder => "Ordner wählen",
            .legal_notice => "Spielinhalte sind nicht enthalten · verwende nur rechtmäßig zugängliche Dateien",
            .sound => "TON",
            .enabled => "Ein",
            .disabled => "Aus",
            .sound_timing => "AudioOut behält das Spiel-Timing auch ohne Tonausgabe bei",
            .controls => "STEUERUNG",
            .gamepad => "Gamepad",
            .keyboard_dualsense => "Tastatur als DualSense",
            .gamepad_keyboard => "Gamepad + Tastatur",
            .controller_description => "XInput-Controller · Standardbelegung",
            .keyboard_description => "WASD, Pfeiltasten und eigene Belegung",
            .hybrid_description => "Beide Eingabequellen arbeiten gleichzeitig",
            .configure_layout => "Tasten belegen  →",
            .core_ready => "Core bereit · Vulkan VideoOut · Windows x86-64",
            .launch_game => "Spiel starten  ▶",
            .input_heading => "Steuerung",
            .input_subtitle => "Eingabequelle wählen und Tasten den DualSense-Buttons zuweisen",
            .keyboard => "Tastatur",
            .hybrid => "Hybrid",
            .xinput_slot => "XInput-Slot",
            .wasd_mapping => "WASD + Belegung",
            .both_sources => "Gamepad + Tastatur",
            .keyboard_layout => "TASTENBELEGUNG",
            .mapping_hint => "Zeile anklicken und Taste drücken. WASD steuert den linken Stick; Alt + Pfeile den rechten.",
            .settings_heading => "Einstellungen",
            .settings_subtitle => "Startoptionen und Projektinformationen",
            .language => "SPRACHE",
            .sound_output => "Tonausgabe",
            .sound_output_description => "Deaktivieren beeinflusst das AudioOut-Timing nicht",
            .fps_counter => "FPS-Anzeige",
            .fps_counter_description => "Bildrate im Titel des Spielfensters anzeigen",
            .compatibility => "Kompatibilität",
            .compatibility_text => "PS5PCEM ist in einer frühen Phase. Nicht jedes Spiel startet; erweiterte DualSense-Funktionen, native PS5-Tastatur/Maus und Controller-zu-Tastatur benötigen weitere HLE-Unterstützung.",
            .author => "Autor: Artur Strazewicz · GitHub: iStark/PS5PCEM",
            .browse_dialog => "Ordner mit dem entschlüsselten PS5-Spiel wählen",
            .nav_saves => "Speicherstände",
            .saves_heading => "Speicherstände",
            .saves_subtitle => "Alle lokalen Speicherstände, nach Titel-ID gruppiert und neben dem Emulator abgelegt.",
            .saves_empty => "Keine lokalen Speicherstände gefunden",
            .saves_open_folder => "Ordner öffnen",
            .pad_test => "Test",
            .pad_test_unavailable => "Controller nicht ansteuerbar",
            .pad_searching => "Controller wird gesucht",
            .pad_absent => "Kein Controller erkannt",
            .status_layout_saved => "Tastenbelegung gespeichert",
            .status_press_key => "Neue Taste drücken · Esc zum Abbrechen",
            .status_input_saved => "Eingabeprofil gespeichert",
            .status_controller_saved => "Controller-Slot gespeichert",
            .status_sound_on => "Ton eingeschaltet",
            .status_sound_off => "Ton ausgeschaltet",
            .status_fps_on => "FPS-Anzeige eingeschaltet",
            .status_fps_off => "FPS-Anzeige ausgeschaltet",
            .status_folder_selected => "Ordner gewählt · startbereit",
            .status_choose_folder => "Zuerst einen Spielordner wählen",
            .status_eboot_missing => "eboot.bin wurde im Ordner und Unterordner decrypted nicht gefunden",
            .status_runner_missing => "game-run.exe fehlt · zuerst zig build ausführen",
            .status_launch_failed => "game-run.exe konnte nicht gestartet werden",
            .status_launched => "Spiel in einem separaten Prozess gestartet",
            .status_game_removed => "Spiel aus der Bibliothek entfernt",
        },
        .french => switch (phrase) {
            .nav_library => "Bibliothèque",
            .nav_input => "Commandes",
            .nav_settings => "Paramètres",
            .project => "PROJET",
            .support_boosty => "Soutenir sur Boosty  ↗",
            .library_heading => "Bibliothèque de jeux",
            .library_subtitle => "Les jeux déjà sélectionnés restent ici avec leur illustration locale",
            .folder_label => "DOSSIER DU JEU",
            .folder_prompt => "Sélectionnez le répertoire contenant eboot.bin",
            .folder_empty => "Aucun dossier sélectionné",
            .choose_folder => "Choisir le dossier",
            .legal_notice => "Les jeux ne sont pas inclus · utilisez uniquement des fichiers obtenus légalement",
            .sound => "SON",
            .enabled => "Activé",
            .disabled => "Désactivé",
            .sound_timing => "AudioOut conserve le rythme du jeu même sans sortie audio",
            .controls => "COMMANDES",
            .gamepad => "Manette",
            .keyboard_dualsense => "Clavier comme DualSense",
            .gamepad_keyboard => "Manette + clavier",
            .controller_description => "Manette XInput · configuration standard",
            .keyboard_description => "WASD, flèches et touches personnalisées",
            .hybrid_description => "Les deux sources fonctionnent simultanément",
            .configure_layout => "Configurer les touches  →",
            .core_ready => "Cœur prêt · Vulkan VideoOut · Windows x86-64",
            .launch_game => "Lancer le jeu  ▶",
            .input_heading => "Commandes",
            .input_subtitle => "Choisissez une source et associez les touches aux boutons DualSense",
            .keyboard => "Clavier",
            .hybrid => "Hybride",
            .xinput_slot => "Emplacement XInput",
            .wasd_mapping => "WASD + touches",
            .both_sources => "Manette + clavier",
            .keyboard_layout => "AFFECTATION DES TOUCHES",
            .mapping_hint => "Cliquez sur une ligne puis pressez une touche. WASD contrôle le stick gauche ; Alt + flèches, le droit.",
            .settings_heading => "Paramètres",
            .settings_subtitle => "Préférences de lancement et informations sur le projet",
            .language => "LANGUE",
            .sound_output => "Sortie audio",
            .sound_output_description => "La désactivation n'affecte pas le rythme AudioOut",
            .fps_counter => "Compteur FPS",
            .fps_counter_description => "Afficher la fréquence d'images dans le titre de la fenêtre",
            .compatibility => "Compatibilité",
            .compatibility_text => "PS5PCEM est encore expérimental. Tous les jeux ne démarrent pas ; les fonctions DualSense avancées, le clavier/souris PS5 natif et la conversion manette-clavier demandent davantage de prise en charge HLE.",
            .author => "Auteur : Artur Strazewicz · GitHub : iStark/PS5PCEM",
            .browse_dialog => "Choisissez le dossier du jeu PS5 déchiffré",
            .nav_saves => "Sauvegardes",
            .saves_heading => "Sauvegardes",
            .saves_subtitle => "Toutes les sauvegardes locales, regroupées par identifiant et stockées près de l’émulateur.",
            .saves_empty => "Aucune sauvegarde locale trouvée",
            .saves_open_folder => "Ouvrir le dossier",
            .pad_test => "Test",
            .pad_test_unavailable => "Manette non pilotable",
            .pad_searching => "Recherche d'une manette",
            .pad_absent => "Aucune manette détectée",
            .status_layout_saved => "Affectation des touches enregistrée",
            .status_press_key => "Pressez une nouvelle touche · Échap pour annuler",
            .status_input_saved => "Profil d'entrée enregistré",
            .status_controller_saved => "Emplacement de manette enregistré",
            .status_sound_on => "Son activé",
            .status_sound_off => "Son désactivé",
            .status_fps_on => "Compteur FPS activé",
            .status_fps_off => "Compteur FPS désactivé",
            .status_folder_selected => "Dossier sélectionné · prêt à lancer",
            .status_choose_folder => "Choisissez d'abord un dossier de jeu",
            .status_eboot_missing => "eboot.bin est introuvable dans le dossier ou le sous-dossier decrypted",
            .status_runner_missing => "game-run.exe est introuvable · exécutez d'abord zig build",
            .status_launch_failed => "Impossible de lancer game-run.exe",
            .status_launched => "Jeu lancé dans un processus séparé",
            .status_game_removed => "Jeu retiré de la bibliothèque",
        },
    };
}

pub fn main(_: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    _ = Win32.SetProcessDpiAwarenessContext(Win32.dpi_awareness_per_monitor_v2);
    _ = Win32.CoInitializeEx(null, Win32.coinit_apartment_threaded);
    defer Win32.CoUninitialize();

    var gdiplus_token: usize = 0;
    const gdiplus_input = Win32.GdiplusStartupInput{};
    gdiplus_ready = Win32.GdiplusStartup(&gdiplus_token, &gdiplus_input, null) == 0;
    defer if (gdiplus_ready) {
        Win32.GdiplusShutdown(gdiplus_token);
        gdiplus_ready = false;
    };

    initializeIniPath();
    loadSettings();
    defer destroyRecentGames();
    createFonts();
    defer destroyFonts();

    const instance = Win32.GetModuleHandleW(null) orelse return error.WindowCreationFailed;
    application_icon = Win32.LoadIconW(instance, Win32.app_icon_resource);
    const class = Win32.WndClassExW{
        .size = @sizeOf(Win32.WndClassExW),
        .style = Win32.class_redraw,
        .window_procedure = windowProcedure,
        .class_extra = 0,
        .window_extra = 0,
        .instance = instance,
        .icon = application_icon,
        .cursor = Win32.LoadCursorW(null, Win32.arrow_cursor),
        .background = null,
        .menu_name = null,
        .class_name = w("PS5PCEM_LAUNCHER"),
        .small_icon = application_icon,
    };
    if (Win32.RegisterClassExW(&class) == 0 and Win32.GetLastError() != Win32.error_class_already_exists) {
        return error.WindowCreationFailed;
    }

    // CreateWindowExW sizes the whole window, frame included, so passing the
    // layout size directly left the client area short of it. The bottom row of
    // the page fell outside and was clipped away, and a taller caption at a
    // higher DPI took more of it.
    var outer = Win32.NativeRect{ .left = 0, .top = 0, .right = window_width, .bottom = window_height };
    _ = Win32.AdjustWindowRect(&outer, Win32.window_style, 0);
    const window = Win32.CreateWindowExW(
        0,
        w("PS5PCEM_LAUNCHER"),
        w("PS5PCEM — Launcher"),
        Win32.window_style,
        Win32.centered,
        Win32.centered,
        outer.right - outer.left,
        outer.bottom - outer.top,
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreationFailed;
    var dark: i32 = 1;
    _ = Win32.DwmSetWindowAttribute(window, 20, &dark, @sizeOf(i32));
    _ = Win32.ShowWindow(window, Win32.show_normal);
    _ = Win32.UpdateWindow(window);
    // Half a second is fast enough to feel immediate for a pad that is plugged
    // in while the launcher is open, and rare enough that the HID scan costs
    // nothing noticeable when none is attached.
    current_window = window;
    pad_presence = input.hid.presence();
    _ = Win32.SetTimer(window, pad_timer_id, 500, null);

    var message: Win32.Message = undefined;
    while (Win32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = Win32.TranslateMessage(&message);
        _ = Win32.DispatchMessageW(&message);
    }
}

fn windowProcedure(
    window: Win32.Window,
    message: u32,
    word_parameter: usize,
    long_parameter: isize,
) callconv(.winapi) isize {
    switch (message) {
        Win32.wm_paint => {
            paint(window);
            return 0;
        },
        Win32.wm_erase_background => return 1,
        Win32.wm_timer => {
            if (word_parameter == pad_test_timer_id) {
                if (!input.hid.advanceTest(pad_test_tick_ms)) {
                    _ = Win32.KillTimer(window, pad_test_timer_id);
                    _ = Win32.InvalidateRect(window, null, 0);
                }
                return 0;
            }
            const found = input.hid.presence();
            if (found.connected != pad_presence.connected or found.family != pad_presence.family) {
                pad_presence = found;
                _ = Win32.InvalidateRect(window, null, 0);
            }
            return 0;
        },
        Win32.wm_device_change => {
            // A pad that was just plugged in should appear now, not at the end
            // of the scan interval.
            input.hid.invalidate();
            pad_presence = input.hid.presence();
            _ = Win32.InvalidateRect(window, null, 0);
            return 0;
        },
        Win32.wm_mouse_move => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter)) >> 16))));
            const next_game = if (current_page == .library) recentGameAt(x, y) else null;
            const next_remove = if (next_game) |index| recentRemoveRect(index).contains(x, y) else false;
            if (next_game != hovered_recent_game or next_remove != hovered_recent_remove) {
                hovered_recent_game = next_game;
                hovered_recent_remove = next_remove;
                _ = Win32.InvalidateRect(window, null, 0);
            }
            if (!tracking_mouse_leave) {
                var tracking = Win32.TrackMouseEventData{
                    .size = @sizeOf(Win32.TrackMouseEventData),
                    .flags = Win32.tme_leave,
                    .window = window,
                    .hover_time = 0,
                };
                tracking_mouse_leave = Win32.TrackMouseEvent(&tracking) != 0;
            }
            return 0;
        },
        Win32.wm_mouse_leave => {
            tracking_mouse_leave = false;
            if (hovered_recent_game != null or hovered_recent_remove) {
                hovered_recent_game = null;
                hovered_recent_remove = false;
                _ = Win32.InvalidateRect(window, null, 0);
            }
            return 0;
        },
        Win32.wm_set_cursor => {
            // Only the client area; the frame keeps the cursors Windows gives
            // it for sizing and the system menu.
            if (@as(u16, @truncate(@as(usize, @bitCast(long_parameter)))) == Win32.hit_test_client) {
                var point = Win32.NativePoint{};
                if (Win32.GetCursorPos(&point) != 0 and Win32.ScreenToClient(window, &point) != 0) {
                    const over = clickableAt(point.x, point.y);
                    _ = Win32.SetCursor(Win32.LoadCursorW(null, if (over) Win32.hand_cursor else Win32.arrow_cursor));
                    return 1;
                }
            }
        },
        Win32.wm_left_button_up => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter)) >> 16))));
            handleClick(window, x, y);
            return 0;
        },
        Win32.wm_key_down => {
            if (capture_mapping) |index| {
                if (word_parameter == 0x1b) {
                    capture_mapping = null;
                } else if (word_parameter < 256) {
                    mapping[index] = @intCast(word_parameter);
                    capture_mapping = null;
                    saveSettings();
                    setStatusPhrase(.status_layout_saved, false);
                }
                _ = Win32.InvalidateRect(window, null, 0);
                return 0;
            }
        },
        Win32.wm_close => {
            _ = Win32.DestroyWindow(window);
            return 0;
        },
        Win32.wm_destroy => {
            input.hid.stopTest();
            Win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return Win32.DefWindowProcW(window, message, word_parameter, long_parameter);
}

/// Every rectangle the pointer can act on, in one place.
///
/// The click handler and the hover cursor have to agree about what is
/// interactive: a hand over something inert, or an arrow over a real button,
/// is worse than having no hand cursor at all. Sharing the geometry is what
/// keeps the two from drifting apart.
const nav_rects = [_]Rect{
    .{ .left = 20, .top = 126, .right = 202, .bottom = 174 },
    .{ .left = 20, .top = 184, .right = 202, .bottom = 232 },
    .{ .left = 20, .top = 242, .right = 202, .bottom = 290 },
    .{ .left = 20, .top = 300, .right = 202, .bottom = 348 },
    .{ .left = 20, .top = 626, .right = 202, .bottom = 670 },
    .{ .left = 20, .top = 680, .right = 202, .bottom = 724 },
};

const library_browse_rect = Rect{ .left = 282, .top = 646, .right = 548, .bottom = 700 };
const library_launch_rect = Rect{ .left = 812, .top = 646, .right = 1086, .bottom = 700 };

fn libraryGameRect(index: usize) Rect {
    const column: i32 = @intCast(index % 4);
    const row: i32 = @intCast(index / 4);
    const left = 282 + column * 201;
    const top = 142 + row * 190;
    return .{ .left = left, .top = top, .right = left + 188, .bottom = top + 178 };
}

fn recentRemoveRect(index: usize) Rect {
    const game = libraryGameRect(index);
    return .{
        .left = game.right - 34,
        .top = game.top + 8,
        .right = game.right - 8,
        .bottom = game.top + 34,
    };
}

fn recentGameAt(x: i32, y: i32) ?usize {
    for (0..recent_game_count) |index| {
        if (libraryGameRect(index).contains(x, y)) return index;
    }
    return null;
}

fn recentRemoveAt(x: i32, y: i32) ?usize {
    for (0..recent_game_count) |index| {
        if (recentRemoveRect(index).contains(x, y)) return index;
    }
    return null;
}

/// Sits beside the presence indicator on the input page.
const pad_test_rect = Rect{ .left = 946, .top = 250, .right = 1086, .bottom = 278 };

const input_mode_rects = [_]Rect{
    .{ .left = 282, .top = 170, .right = 532, .bottom = 246 },
    .{ .left = 548, .top = 170, .right = 798, .bottom = 246 },
    .{ .left = 814, .top = 170, .right = 1086, .bottom = 246 },
};

const language_rects = [_]Rect{
    .{ .left = 282, .top = 190, .right = 472, .bottom = 246 },
    .{ .left = 486, .top = 190, .right = 676, .bottom = 246 },
    .{ .left = 690, .top = 190, .right = 880, .bottom = 246 },
    .{ .left = 894, .top = 190, .right = 1086, .bottom = 246 },
};

const settings_toggle_rects = [_]Rect{
    .{ .left = 282, .top = 278, .right = 1086, .bottom = 360 },
    .{ .left = 282, .top = 382, .right = 1086, .bottom = 464 },
};

fn controllerSlotRect(index: usize) Rect {
    const left = 406 + @as(i32, @intCast(index)) * 28;
    return .{ .left = left, .top = 212, .right = left + 24, .bottom = 238 };
}

fn mappingRect(index: usize) Rect {
    const column: i32 = @intCast(index / 7);
    const row: i32 = @intCast(index % 7);
    return .{
        .left = 282 + column * 404,
        .top = 310 + row * 48,
        .right = 660 + column * 404,
        .bottom = 350 + row * 48,
    };
}

fn indexOfRect(rects: []const Rect, x: i32, y: i32) ?usize {
    for (rects, 0..) |rectangle, index| {
        if (rectangle.contains(x, y)) return index;
    }
    return null;
}

/// Whether the pointer is over something that responds to a click.
fn clickableAt(x: i32, y: i32) bool {
    if (indexOfRect(&nav_rects, x, y) != null) return true;
    return switch (current_page) {
        .library => recentGameAt(x, y) != null or
            library_browse_rect.contains(x, y) or
            library_launch_rect.contains(x, y),
        .input => blk: {
            if (pad_presence.connected and pad_test_rect.contains(x, y)) break :blk true;
            if (indexOfRect(&input_mode_rects, x, y) != null) break :blk true;
            for (0..4) |index| {
                if (controllerSlotRect(index).contains(x, y)) break :blk true;
            }
            for (0..mapping.len) |index| {
                if (mappingRect(index).contains(x, y)) break :blk true;
            }
            break :blk false;
        },
        .saves => saves_open_rect.contains(x, y),
        .settings => indexOfRect(&language_rects, x, y) != null or
            indexOfRect(&settings_toggle_rects, x, y) != null,
    };
}

fn handleClick(window: Win32.Window, x: i32, y: i32) void {
    if (indexOfRect(&nav_rects, x, y)) |index| {
        switch (index) {
            0 => current_page = .library,
            1 => current_page = .input,
            2 => current_page = .saves,
            3 => current_page = .settings,
            4 => openBoosty(window),
            else => openGithub(window),
        }
        if (current_page != .library) {
            hovered_recent_game = null;
            hovered_recent_remove = false;
        }
    } else switch (current_page) {
        .library => handleLibraryClick(window, x, y),
        .input => handleInputClick(x, y),
        .saves => handleSavesClick(window, x, y),
        .settings => handleSettingsClick(x, y),
    }
    _ = Win32.InvalidateRect(window, null, 0);
}

fn handleLibraryClick(window: Win32.Window, x: i32, y: i32) void {
    if (recentRemoveAt(x, y)) |index| {
        removeRecentGame(index);
        return;
    }
    if (recentGameAt(x, y)) |index| {
        selectRecentGame(index);
        return;
    }
    if (library_browse_rect.contains(x, y)) chooseGameFolder(window);
    if (library_launch_rect.contains(x, y)) launchGame(window);
}

fn handleInputClick(x: i32, y: i32) void {
    if (pad_presence.connected and pad_test_rect.contains(x, y)) {
        if (input.hid.startTest()) {
            // A short timer drives the colour steps; the half-second presence
            // timer is far too coarse to walk through them.
            _ = Win32.SetTimer(current_window, pad_test_timer_id, pad_test_tick_ms, null);
            setStatusPhrase(.pad_test, false);
        } else {
            setStatusPhrase(.pad_test_unavailable, true);
        }
        return;
    }
    for (0..4) |index| {
        if (controllerSlotRect(index).contains(x, y)) {
            controller_index = @intCast(index);
            saveSettings();
            setStatusPhrase(.status_controller_saved, false);
            return;
        }
    }
    if (indexOfRect(&input_mode_rects, x, y)) |index| {
        input_mode = @enumFromInt(index);
        saveSettings();
        setStatusPhrase(.status_input_saved, false);
        return;
    }
    for (0..mapping.len) |index| {
        if (mappingRect(index).contains(x, y)) {
            capture_mapping = index;
            setStatusPhrase(.status_press_key, false);
            return;
        }
    }
}

fn handleSettingsClick(x: i32, y: i32) void {
    if (indexOfRect(&language_rects, x, y)) |index| {
        language = @enumFromInt(index);
        status_length = 0;
        saveSettings();
        return;
    }
    const toggle = indexOfRect(&settings_toggle_rects, x, y) orelse return;
    if (toggle == 0) {
        sound_enabled = !sound_enabled;
        saveSettings();
        setStatusPhrase(if (sound_enabled) .status_sound_on else .status_sound_off, false);
    } else {
        show_fps = !show_fps;
        saveSettings();
        setStatusPhrase(if (show_fps) .status_fps_on else .status_fps_off, false);
    }
}

fn paint(window: Win32.Window) void {
    var paint_data: Win32.PaintStruct = undefined;
    const dc = Win32.BeginPaint(window, &paint_data) orelse return;
    defer _ = Win32.EndPaint(window, &paint_data);

    var client: Win32.NativeRect = undefined;
    _ = Win32.GetClientRect(window, &client);
    fill(dc, .{ .left = 0, .top = 0, .right = client.right, .bottom = client.bottom }, 0x0015110e);
    fill(dc, .{ .left = 0, .top = 0, .right = sidebar_width, .bottom = client.bottom }, 0x00201915);
    fill(dc, .{ .left = sidebar_width, .top = 0, .right = sidebar_width + 1, .bottom = client.bottom }, 0x00352b25);

    drawBrand(dc);
    drawNavigation(dc);
    switch (current_page) {
        .library => drawLibrary(dc),
        .input => drawInput(dc),
        .saves => drawSaves(dc),
        .settings => drawSettings(dc),
    }
    drawFooter(dc);
}

fn drawBrand(dc: Win32.DeviceContext) void {
    _ = Win32.DrawIconEx(dc, 24, 28, application_icon, 44, 44, 0, null, Win32.di_normal);
    text(dc, w("PS5PCEM"), -1, .{ .left = 80, .top = 31, .right = 216, .bottom = 56 }, 0x00f4f0ea, title_font, Win32.dt_left);
    text(dc, w("LAUNCHER · PREVIEW"), -1, .{ .left = 80, .top = 57, .right = 216, .bottom = 76 }, 0x009b9088, small_font, Win32.dt_left);
}

fn drawNavigation(dc: Win32.DeviceContext) void {
    drawNavItem(dc, .library, 126, .nav_library, "01");
    drawNavItem(dc, .input, 184, .nav_input, "02");
    drawNavItem(dc, .saves, 242, .nav_saves, "03");
    drawNavItem(dc, .settings, 300, .nav_settings, "04");
    localizedText(dc, .project, .{ .left = 28, .top = 596, .right = 190, .bottom = 616 }, 0x007c716a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    roundFill(dc, .{ .left = 20, .top = 626, .right = 202, .bottom = 670 }, 10, 0x003d3029);
    localizedText(dc, .support_boosty, .{ .left = 32, .top = 639, .right = 192, .bottom = 660 }, 0x00ffac64, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    text(dc, w("GitHub · iStark  ↗"), -1, .{ .left = 28, .top = 690, .right = 198, .bottom = 716 }, 0x00b9afa8, regular_font, Win32.dt_left);
}

fn drawNavItem(dc: Win32.DeviceContext, page: Page, top: i32, label: Phrase, comptime index: []const u8) void {
    if (current_page == page) roundFill(dc, .{ .left = 20, .top = top, .right = 202, .bottom = top + 48 }, 12, 0x003d3029);
    const color: u32 = if (current_page == page) 0x00fff8f1 else 0x00a39890;
    text(dc, w(index), -1, .{ .left = 34, .top = top + 15, .right = 58, .bottom = top + 38 }, if (current_page == page) 0x00ffac64 else 0x006d625b, small_font, Win32.dt_left);
    localizedText(dc, label, .{ .left = 66, .top = top + 13, .right = 200, .bottom = top + 39 }, color, medium_font, Win32.dt_left);
}

fn drawLibrary(dc: Win32.DeviceContext) void {
    pageHeading(dc, .library_heading, .library_subtitle);

    if (recent_game_count == 0) {
        card(dc, .{ .left = 282, .top = 158, .right = 1086, .bottom = 510 });
        localizedText(dc, .folder_prompt, .{ .left = 330, .top = 300, .right = 1038, .bottom = 332 }, 0x00f4f0ea, title_font, Win32.dt_center | Win32.dt_end_ellipsis);
        localizedText(dc, .folder_empty, .{ .left = 330, .top = 350, .right = 1038, .bottom = 376 }, 0x008b817a, regular_font, Win32.dt_center | Win32.dt_end_ellipsis);
    } else {
        for (recent_games[0..recent_game_count], 0..) |game, index| {
            drawLibraryGame(dc, game, index);
        }
    }

    card(dc, .{ .left = 282, .top = 536, .right = 1086, .bottom = 622 });
    localizedText(dc, .folder_label, .{ .left = 306, .top = 552, .right = 520, .bottom = 572 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    if (game_folder_length == 0) {
        localizedText(dc, .folder_empty, .{ .left = 306, .top = 582, .right = 1058, .bottom = 607 }, 0x007e746d, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    } else {
        text(dc, &game_folder, @intCast(game_folder_length), .{ .left = 306, .top = 580, .right = 1058, .bottom = 607 }, 0x00d8d0c9, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    }

    button(dc, library_browse_rect, .choose_folder, false);
    localizedText(dc, .legal_notice, .{ .left = 566, .top = 666, .right = 794, .bottom = 688 }, 0x007e746d, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
    button(dc, library_launch_rect, .launch_game, game_folder_length == 0);
}

fn drawLibraryGame(dc: Win32.DeviceContext, game: RecentGame, index: usize) void {
    const rectangle = libraryGameRect(index);
    const selected = sameFolder(game.folder[0..game.folder_length], game_folder[0..game_folder_length]);
    roundFill(dc, rectangle, 12, if (selected) 0x0049362b else 0x00251f1b);
    const artwork = Rect{
        .left = rectangle.left + 26,
        .top = rectangle.top + 10,
        .right = rectangle.right - 26,
        .bottom = rectangle.top + 146,
    };
    if (game.icon) |icon| {
        drawBitmap(dc, icon, artwork);
    } else {
        roundFill(dc, artwork, 10, 0x00352c27);
        text(dc, w("PS5"), -1, .{ .left = artwork.left, .top = artwork.top + 52, .right = artwork.right, .bottom = artwork.bottom }, 0x00ffac64, title_font, Win32.dt_center);
    }
    if (game.title_length != 0) {
        text(dc, &game.title, @intCast(game.title_length), .{ .left = rectangle.left + 10, .top = rectangle.top + 151, .right = rectangle.right - 10, .bottom = rectangle.bottom - 6 }, 0x00f4f0ea, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
    } else {
        text(dc, &game.identifier, @intCast(game.identifier_length), .{ .left = rectangle.left + 10, .top = rectangle.top + 151, .right = rectangle.right - 10, .bottom = rectangle.bottom - 6 }, 0x00a39890, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
    }
    if (hovered_recent_game == index) {
        const remove = recentRemoveRect(index);
        roundFill(dc, remove, 13, if (hovered_recent_remove) 0x004848d8 else 0x00403934);
        text(dc, w("×"), -1, .{ .left = remove.left, .top = remove.top + 2, .right = remove.right, .bottom = remove.bottom }, 0x00f4f0ea, medium_font, Win32.dt_center);
    }
}

fn drawInput(dc: Win32.DeviceContext) void {
    pageHeading(dc, .input_heading, .input_subtitle);
    drawModeCard(dc, .controller, .{ .left = 282, .top = 170, .right = 532, .bottom = 246 }, .gamepad, .xinput_slot);
    drawModeCard(dc, .keyboard, .{ .left = 548, .top = 170, .right = 798, .bottom = 246 }, .keyboard, .wasd_mapping);
    drawModeCard(dc, .hybrid, .{ .left = 814, .top = 170, .right = 1086, .bottom = 246 }, .hybrid, .both_sources);
    for (0..4) |index| {
        const left = 406 + @as(i32, @intCast(index)) * 28;
        const selected = controller_index == index;
        roundFill(dc, .{ .left = left, .top = 212, .right = left + 24, .bottom = 238 }, 6, if (selected) 0x00ff9c3d else 0x00352c27);
        var number = [_:0]u16{@as(u16, '1') + @as(u16, @intCast(index))};
        text(dc, &number, 1, .{ .left = left, .top = 218, .right = left + 24, .bottom = 234 }, if (selected) 0x00181510 else 0x00a89e96, small_font, Win32.dt_center);
    }

    drawPadPresence(dc);
    drawPadTest(dc);

    localizedText(dc, .keyboard_layout, .{ .left = 282, .top = 278, .right = 650, .bottom = 300 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    for (0..mapping.len) |index| {
        const column: i32 = @intCast(index / 7);
        const row: i32 = @intCast(index % 7);
        const left = 282 + column * 404;
        const top = 310 + row * 48;
        roundFill(dc, .{ .left = left, .top = top, .right = left + 378, .bottom = top + 40 }, 8, if (capture_mapping == index) 0x0042362e else 0x00251f1b);
        textUtf8(dc, mapping_names[index], .{ .left = left + 14, .top = top + 11, .right = left + 210, .bottom = top + 32 }, 0x00d8d0c9, regular_font, Win32.dt_left);
        var key_buffer: [48]u16 = undefined;
        const key_length = keyDisplayName(mapping[index], &key_buffer);
        text(dc, &key_buffer, @intCast(key_length), .{ .left = left + 218, .top = top + 10, .right = left + 356, .bottom = top + 33 }, if (capture_mapping == index) 0x00ffac64 else 0x00f4f0ea, medium_font, Win32.dt_right);
    }
    localizedText(dc, .mapping_hint, .{ .left = 282, .top = 660, .right = 1086, .bottom = 686 }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
}

/// Reports whether a Sony pad is attached, and which one.
///
/// The XInput slot beside it selects an Xbox-compatible controller; a DualSense
/// or DualShock 4 is read straight from HID and needs no slot, so saying which
/// path is live is the only way to tell that a connected pad will actually be
/// heard.
fn drawPadPresence(dc: Win32.DeviceContext) void {
    const area = Rect{ .left = 282, .top = 252, .right = 1086, .bottom = 274 };
    const connected = pad_presence.connected;
    roundFill(dc, .{ .left = area.left, .top = area.top + 6, .right = area.left + 10, .bottom = area.top + 16 }, 5, if (connected) 0x0055c46a else 0x00554a44);
    if (pad_presence.family) |family| {
        const name = switch (family) {
            .dual_sense => "DualSense",
            .dual_shock_4 => "DualShock 4",
        };
        textUtf8(dc, name, .{ .left = area.left + 20, .top = area.top, .right = area.right, .bottom = area.bottom }, 0x00d8d0c9, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
        return;
    }
    localizedText(dc, .pad_absent, .{ .left = area.left + 20, .top = area.top, .right = area.right, .bottom = area.bottom }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
}

/// Runs the pad through a second of rumble and its colour sweep, so a player
/// can tell a pad that is merely detected from one the host can actually drive.
fn drawPadTest(dc: Win32.DeviceContext) void {
    if (!pad_presence.connected) return;
    const running = input.hid.testRunning();
    roundFill(dc, pad_test_rect, 8, if (running) 0x00ff9c3d else 0x00352c27);

    // The swatch is the light bar the pad is showing at this instant, so the
    // button doubles as the readout for its own test: a pad that rumbles but
    // never lights up is visible here without watching the hardware.
    const swatch = Rect{
        .left = pad_test_rect.left + 12,
        .top = pad_test_rect.top + 8,
        .right = pad_test_rect.left + 24,
        .bottom = pad_test_rect.top + 20,
    };
    const swatch_colour: u32 = if (input.hid.testColour()) |colour|
        deviceColour(colour[0], colour[1], colour[2])
    else if (running)
        0x00181510
    else
        0x00a89e96;
    roundFill(dc, swatch, 6, swatch_colour);

    localizedText(
        dc,
        .pad_test,
        .{ .left = swatch.right + 8, .top = pad_test_rect.top + 6, .right = pad_test_rect.right - 10, .bottom = pad_test_rect.bottom },
        if (running) 0x00181510 else 0x00d8d0c9,
        small_font,
        Win32.dt_center | Win32.dt_end_ellipsis,
    );
}

/// GDI takes its colours as blue, green and red packed low to high, which is
/// the reverse of the order the pad reports them in.
fn deviceColour(red: u8, green: u8, blue: u8) u32 {
    return (@as(u32, blue) << 16) | (@as(u32, green) << 8) | @as(u32, red);
}

/// Opens the host directory holding the selected title's saves.
const saves_open_rect = Rect{ .left = 880, .top = 148, .right = 1086, .bottom = 190 };

/// How many slots the page will list. A title with more has written more saves
/// than a launcher page can usefully show at once.
const maximum_listed_saves = 12;

const SaveSlot = struct {
    title_id: [32]u16 = @splat(0),
    title_id_length: usize = 0,
    name: [64]u16 = @splat(0),
    name_length: usize = 0,
    detail: [96]u16 = @splat(0),
    detail_length: usize = 0,
};

var save_slots: [maximum_listed_saves]SaveSlot = @splat(.{});
var save_slot_count: usize = 0;
var save_scan_done = false;

/// Rescans on the next paint. A selection change moves that title's slots to
/// the front while retaining saves from the rest of the library.
fn invalidateSaves() void {
    save_scan_done = false;
}

/// Builds the selected title's save path, or the all-title root when there is
/// no current title. The Saves page can therefore remain useful on startup.
fn saveDirectoryPath(output: *[1024]u16) usize {
    var length = saveRootDirectoryPath(output);
    if (length == 0) return 0;
    if (title_identifier_length == 0) {
        return length;
    }
    if (length + 1 >= output.len) return 0;
    output[length] = '\\';
    length += 1;
    if (length + title_identifier_length >= output.len) return 0;
    @memcpy(output[length..][0..title_identifier_length], title_identifier[0..title_identifier_length]);
    length += title_identifier_length;
    output[length] = 0;
    return length;
}

fn saveRootDirectoryPath(output: *[1024]u16) usize {
    var length = emulatorHomeDirectory(output);
    if (length == 0) return 0;
    const savedata = w("savedata");
    const savedata_length = wideLength(savedata);
    if (length + savedata_length >= output.len) return 0;
    @memcpy(output[length..][0..savedata_length], savedata[0..savedata_length]);
    length += savedata_length;
    output[length] = 0;
    return length;
}

/// The directory the launcher itself lives in.
fn siblingDirectory(output: *[1024]u16) usize {
    var length = Win32.GetModuleFileNameW(null, output, output.len);
    if (length == 0 or length >= output.len) return 0;
    while (length > 0 and output[length - 1] != '\\') : (length -= 1) {}
    return length;
}

/// Development builds live in `<root>/zig-out/bin`, while packaged builds put
/// the launcher directly in their root. Normalize both to the directory which
/// owns `savedata`, logs and the Vulkan driver cache.
fn emulatorHomeDirectory(output: *[1024]u16) usize {
    var length = siblingDirectory(output);
    if (length == 0) return 0;
    const development_tail = w("zig-out\\bin\\");
    const tail_length = wideLength(development_tail);
    if (length >= tail_length and
        sameFolder(output[length - tail_length .. length], development_tail[0..tail_length]))
    {
        length -= tail_length;
        output[length] = 0;
    }
    return length;
}

/// Lists every local title's slots, with the selected title first.
fn scanSaves() void {
    save_slot_count = 0;
    save_scan_done = true;

    var root: [1024]u16 = @splat(0);
    var root_length = emulatorHomeDirectory(&root);
    if (root_length == 0) return;
    const savedata = w("savedata");
    const savedata_length = wideLength(savedata);
    if (root_length + savedata_length >= root.len) return;
    @memcpy(root[root_length..][0..savedata_length], savedata[0..savedata_length]);
    root_length += savedata_length;
    root[root_length] = 0;

    // Put the selected title first, then continue through every other title
    // root. The Saves page is a library browser, so selecting a game without a
    // save must not make existing saves from all other games disappear.
    if (title_identifier_length != 0) {
        var selected: [1024]u16 = root;
        var selected_length = root_length;
        if (selected_length + 1 + title_identifier_length < selected.len) {
            selected[selected_length] = '\\';
            selected_length += 1;
            @memcpy(selected[selected_length..][0..title_identifier_length], title_identifier[0..title_identifier_length]);
            selected_length += title_identifier_length;
            selected[selected_length] = 0;
            scanTitleSaveSlots(&selected, selected_length, title_identifier[0..title_identifier_length]);
        }
    }

    // FindFirstFileW wants a pattern rather than a directory.
    const pattern = w("\\*");
    const pattern_length = wideLength(pattern);
    var search: [1024]u16 = root;
    if (root_length + pattern_length >= search.len) return;
    @memcpy(search[root_length..][0..pattern_length], pattern[0..pattern_length]);
    search[root_length + pattern_length] = 0;

    var found: Win32.FindData = undefined;
    const handle = Win32.FindFirstFileW(@ptrCast(&search), &found);
    if (@intFromPtr(handle) == Win32.invalid_handle) return;
    defer _ = Win32.FindClose(handle);

    while (true) {
        const is_directory = found.attributes & Win32.file_attribute_directory != 0;
        const name_length = wideLength(@ptrCast(&found.name));
        const skip = !is_directory or name_length == 0 or found.name[0] == '.';
        const is_selected = title_identifier_length != 0 and
            sameFolder(found.name[0..name_length], title_identifier[0..title_identifier_length]);
        if (!skip and !is_selected and save_slot_count < save_slots.len) {
            var title_root: [1024]u16 = root;
            var length = root_length;
            if (length + 1 + name_length < title_root.len) {
                title_root[length] = '\\';
                length += 1;
                @memcpy(title_root[length..][0..name_length], found.name[0..name_length]);
                length += name_length;
                title_root[length] = 0;
                scanTitleSaveSlots(&title_root, length, found.name[0..name_length]);
            }
        }
        if (Win32.FindNextFileW(handle, &found) == 0) break;
    }
}

fn scanTitleSaveSlots(root: *[1024]u16, root_length: usize, title_id: []const u16) void {
    const pattern = w("\\*");
    const pattern_length = wideLength(pattern);
    if (root_length + pattern_length >= root.len) return;
    @memcpy(root[root_length..][0..pattern_length], pattern[0..pattern_length]);
    root[root_length + pattern_length] = 0;

    var found: Win32.FindData = undefined;
    const handle = Win32.FindFirstFileW(@ptrCast(root), &found);
    if (@intFromPtr(handle) == Win32.invalid_handle) return;
    defer _ = Win32.FindClose(handle);
    while (true) {
        const is_directory = found.attributes & Win32.file_attribute_directory != 0;
        const name_length = wideLength(@ptrCast(&found.name));
        if (is_directory and name_length != 0 and found.name[0] != '.' and save_slot_count < save_slots.len) {
            var slot = SaveSlot{};
            slot.title_id_length = @min(title_id.len, slot.title_id.len - 1);
            @memcpy(slot.title_id[0..slot.title_id_length], title_id[0..slot.title_id_length]);
            slot.name_length = @min(name_length, slot.name.len - 1);
            @memcpy(slot.name[0..slot.name_length], found.name[0..slot.name_length]);
            slot.detail_length = describeSlot(root, root_length, found.name[0..name_length], &slot.detail);
            save_slots[save_slot_count] = slot;
            save_slot_count += 1;
        }
        if (Win32.FindNextFileW(handle, &found) == 0) break;
    }
    root[root_length] = 0;
}

/// Reads the title a slot recorded for itself, falling back to its size.
///
/// The descriptive parameters are what a save browser is for: a directory name
/// is chosen by the game and often means nothing to the player.
fn describeSlot(
    root: *[1024]u16,
    root_length: usize,
    name: []const u16,
    output: *[96]u16,
) usize {
    var path: [1024]u16 = undefined;
    @memcpy(path[0..root_length], root[0..root_length]);
    var length = root_length;
    const separator = w("\\");
    const tail = w("\\sce_sys\\param.txt");
    if (length + name.len + wideLength(tail) + 2 >= path.len) return 0;
    const separator_length = wideLength(separator);
    @memcpy(path[length..][0..separator_length], separator[0..separator_length]);
    length += separator_length;
    @memcpy(path[length..][0..name.len], name);
    length += name.len;
    const tail_length = wideLength(tail);
    @memcpy(path[length..][0..tail_length], tail[0..tail_length]);
    length += tail_length;
    path[length] = 0;

    var contents: [512]u8 = undefined;
    const read = readSmallFile(@ptrCast(&path), &contents) orelse return 0;
    const title = parameterValue(read, "title=") orelse return 0;
    var written: usize = 0;
    for (title) |byte| {
        if (written + 1 >= output.len) break;
        output[written] = byte;
        written += 1;
    }
    output[written] = 0;
    return written;
}

/// Reads the first record of a parameter file. Only the title is shown, so the
/// rest of the file is not parsed.
fn parameterValue(document: []const u8, key: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < document.len) {
        var end = cursor;
        while (end < document.len and document[end] != '\n') end += 1;
        var line = document[cursor..end];
        while (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > key.len and std.mem.eql(u8, line[0..key.len], key)) {
            const value = line[key.len..];
            return if (value.len == 0) null else value;
        }
        cursor = end + 1;
    }
    return null;
}

fn readSmallFile(path: [*:0]const u16, buffer: []u8) ?[]const u8 {
    const handle = Win32.CreateFileW(
        path,
        Win32.generic_read,
        Win32.file_share_read,
        null,
        Win32.open_existing,
        0,
        null,
    );
    if (@intFromPtr(handle) == Win32.invalid_handle) return null;
    defer _ = Win32.CloseHandle(handle);
    var read: u32 = 0;
    if (Win32.ReadFile(handle, buffer.ptr, @intCast(buffer.len), &read, null) == 0) return null;
    return buffer[0..read];
}

fn sameFolder(first: []const u16, second: []const u16) bool {
    if (first.len == 0 or first.len != second.len) return false;
    return Win32.CompareStringOrdinal(first.ptr, @intCast(first.len), second.ptr, @intCast(second.len), 1) == Win32.cstr_equal;
}

fn childPath(output: *[1024]u16, folder: []const u16, comptime suffix: []const u8) usize {
    if (folder.len >= output.len) return 0;
    @memcpy(output[0..folder.len], folder);
    var converted: [128]u16 = undefined;
    const suffix_length = std.unicode.utf8ToUtf16Le(&converted, suffix) catch return 0;
    if (folder.len + suffix_length >= output.len) return 0;
    @memcpy(output[folder.len..][0..suffix_length], converted[0..suffix_length]);
    const length = folder.len + suffix_length;
    output[length] = 0;
    return length;
}

fn loadGameIcon(folder: []const u16) Win32.Bitmap {
    if (!gdiplus_ready) return null;
    var path: [1024]u16 = @splat(0);
    if (childPath(&path, folder, "\\sce_sys\\icon0.png") == 0) return null;
    if (Win32.GetFileAttributesW(@ptrCast(&path)) == Win32.invalid_file_attributes) return null;

    var source: Win32.GdiPlusImage = null;
    if (Win32.GdipCreateBitmapFromFile(@ptrCast(&path), &source) != 0) return null;
    const source_image = source orelse return null;
    defer _ = Win32.GdipDisposeImage(source_image);

    var thumbnail: Win32.GdiPlusImage = null;
    if (Win32.GdipGetImageThumbnail(source_image, 136, 136, &thumbnail, null, null) != 0) return null;
    const thumbnail_image = thumbnail orelse return null;
    defer _ = Win32.GdipDisposeImage(thumbnail_image);

    // The card uses an opaque GDI blit. Flatten transparent PNG pixels against
    // its background while GDI+ still understands the source alpha channel.
    var bitmap: Win32.Bitmap = null;
    if (Win32.GdipCreateHBITMAPFromBitmap(thumbnail_image, &bitmap, 0xff1b1f25) != 0) return null;
    return bitmap;
}

fn fallbackFolderTitle(folder: []const u16, output: *[128]u16) usize {
    var start = folder.len;
    while (start > 0 and folder[start - 1] != '\\' and folder[start - 1] != '/') : (start -= 1) {}
    const length = @min(folder.len - start, output.len - 1);
    @memcpy(output[0..length], folder[start..][0..length]);
    output[length] = 0;
    return length;
}

fn loadRecentGame(folder: []const u16) ?RecentGame {
    if (folder.len == 0 or folder.len >= 1024) return null;
    var game = RecentGame{};
    @memcpy(game.folder[0..folder.len], folder);
    game.folder_length = folder.len;

    var path: [1024]u16 = @splat(0);
    if (childPath(&path, folder, "\\sce_sys\\param.json") != 0) {
        var document: [8192]u8 = undefined;
        if (readSmallFile(@ptrCast(&path), &document)) |bytes| {
            if (jsonStringValue(bytes, "\"titleName\"")) |value| {
                game.title_length = std.unicode.utf8ToUtf16Le(&game.title, value) catch 0;
                game.title[game.title_length] = 0;
            }
            if (jsonStringValue(bytes, "\"titleId\"")) |value| {
                game.identifier_length = std.unicode.utf8ToUtf16Le(&game.identifier, value) catch 0;
                game.identifier[game.identifier_length] = 0;
            }
        }
    }
    if (game.title_length == 0) game.title_length = fallbackFolderTitle(folder, &game.title);
    game.icon = loadGameIcon(folder);
    return game;
}

fn recentKey(index: usize, output: *[32]u16) void {
    var utf8: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    stream.print("path_{d}", .{index}) catch return;
    const converted = std.unicode.utf8ToUtf16Le(output, stream.buffered()) catch return;
    output[converted] = 0;
}

fn saveRecentGames() void {
    if (ini_path_length == 0) return;
    for (0..maximum_recent_games) |index| {
        var key: [32]u16 = @splat(0);
        recentKey(index, &key);
        const value: ?[*:0]const u16 = if (index < recent_game_count)
            @ptrCast(&recent_games[index].folder)
        else
            null;
        _ = Win32.WritePrivateProfileStringW(w("recent"), @ptrCast(&key), value, @ptrCast(&ini_path));
    }
}

fn rememberGameFolder(folder: []const u16, persist: bool) void {
    const candidate = loadRecentGame(folder) orelse return;
    var existing: ?usize = null;
    for (recent_games[0..recent_game_count], 0..) |game, index| {
        if (sameFolder(game.folder[0..game.folder_length], folder)) {
            existing = index;
            break;
        }
    }

    if (existing) |index| {
        if (recent_games[index].icon != null) _ = Win32.DeleteObject(recent_games[index].icon);
        var cursor = index;
        while (cursor > 0) : (cursor -= 1) recent_games[cursor] = recent_games[cursor - 1];
    } else {
        if (recent_game_count == maximum_recent_games) {
            if (recent_games[maximum_recent_games - 1].icon != null) {
                _ = Win32.DeleteObject(recent_games[maximum_recent_games - 1].icon);
            }
        } else {
            recent_game_count += 1;
        }
        var cursor = recent_game_count - 1;
        while (cursor > 0) : (cursor -= 1) recent_games[cursor] = recent_games[cursor - 1];
    }
    recent_games[0] = candidate;
    if (persist) saveRecentGames();
}

fn loadRecentGames() void {
    if (ini_path_length == 0) return;
    for (0..maximum_recent_games) |index| {
        var key: [32]u16 = @splat(0);
        recentKey(index, &key);
        var folder: [1024]u16 = @splat(0);
        const length = Win32.GetPrivateProfileStringW(w("recent"), @ptrCast(&key), w(""), &folder, folder.len, @ptrCast(&ini_path));
        if (length == 0) continue;
        const game = loadRecentGame(folder[0..length]) orelse continue;
        if (recent_game_count == maximum_recent_games) break;
        recent_games[recent_game_count] = game;
        recent_game_count += 1;
    }
}

fn destroyRecentGames() void {
    for (recent_games[0..recent_game_count]) |game| {
        if (game.icon != null) _ = Win32.DeleteObject(game.icon);
    }
    recent_game_count = 0;
}

/// Removes only the launcher's reference. The installed game and every save
/// remain untouched on disk.
fn removeRecentGame(index: usize) void {
    if (index >= recent_game_count) return;
    const removed_selected = sameFolder(
        recent_games[index].folder[0..recent_games[index].folder_length],
        game_folder[0..game_folder_length],
    );
    if (recent_games[index].icon != null) _ = Win32.DeleteObject(recent_games[index].icon);

    var cursor = index;
    while (cursor + 1 < recent_game_count) : (cursor += 1) {
        recent_games[cursor] = recent_games[cursor + 1];
    }
    recent_game_count -= 1;
    recent_games[recent_game_count] = .{};
    hovered_recent_game = null;
    hovered_recent_remove = false;
    saveRecentGames();

    if (removed_selected) {
        @memset(&game_folder, 0);
        game_folder_length = 0;
        refreshTitleIdentifier();
        saveSettings();
    }
    setStatusPhrase(.status_game_removed, false);
}

fn selectRecentGame(index: usize) void {
    if (index >= recent_game_count) return;
    const selected = recent_games[index];
    @memset(&game_folder, 0);
    @memcpy(game_folder[0..selected.folder_length], selected.folder[0..selected.folder_length]);
    game_folder_length = selected.folder_length;
    refreshTitleIdentifier();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    saveSettings();
    setStatusPhrase(.status_folder_selected, false);
}

/// Reads the selected title's product code out of the document it ships.
///
/// The launcher needs the same identifier the emulator keys saves by; deriving
/// it from the folder name instead would disagree the moment a dump is renamed.
fn refreshTitleIdentifier() void {
    title_identifier_length = 0;
    invalidateSaves();
    if (game_folder_length == 0) return;

    var path: [1024]u16 = undefined;
    if (game_folder_length >= path.len) return;
    @memcpy(path[0..game_folder_length], game_folder[0..game_folder_length]);
    var length = game_folder_length;
    const tail = w("\\sce_sys\\param.json");
    const tail_length = wideLength(tail);
    if (length + tail_length >= path.len) return;
    @memcpy(path[length..][0..tail_length], tail[0..tail_length]);
    length += tail_length;
    path[length] = 0;

    var document: [8192]u8 = undefined;
    const text_bytes = readSmallFile(@ptrCast(&path), &document) orelse return;
    const value = jsonStringValue(text_bytes, "\"titleId\"") orelse return;
    for (value) |byte| {
        if (title_identifier_length + 1 >= title_identifier.len) break;
        title_identifier[title_identifier_length] = byte;
        title_identifier_length += 1;
    }
    title_identifier[title_identifier_length] = 0;
}

/// Finds a quoted string value following a quoted key.
fn jsonStringValue(document: []const u8, quoted_key: []const u8) ?[]const u8 {
    const key_at = std.mem.indexOf(u8, document, quoted_key) orelse return null;
    var cursor = key_at + quoted_key.len;
    while (cursor < document.len and (document[cursor] == ' ' or document[cursor] == '\t')) cursor += 1;
    if (cursor >= document.len or document[cursor] != ':') return null;
    cursor += 1;
    while (cursor < document.len and
        (document[cursor] == ' ' or document[cursor] == '\t' or
            document[cursor] == '\r' or document[cursor] == '\n')) cursor += 1;
    if (cursor >= document.len or document[cursor] != '"') return null;
    const start = cursor + 1;
    const end = std.mem.indexOfScalarPos(u8, document, start, '"') orelse return null;
    return document[start..end];
}

fn handleSavesClick(window: Win32.Window, x: i32, y: i32) void {
    if (!saves_open_rect.contains(x, y)) return;
    var path: [1024]u16 = undefined;
    var length = saveDirectoryPath(&path);
    if (length == 0) return;
    if (Win32.GetFileAttributesW(@ptrCast(&path)) == Win32.invalid_file_attributes) {
        length = saveRootDirectoryPath(&path);
        if (length == 0 or Win32.GetFileAttributesW(@ptrCast(&path)) == Win32.invalid_file_attributes) return;
    }
    _ = Win32.ShellExecuteW(window, w("open"), @ptrCast(&path), null, null, Win32.show_normal);
}

fn drawSaves(dc: Win32.DeviceContext) void {
    pageHeading(dc, .saves_heading, .saves_subtitle);
    if (!save_scan_done) scanSaves();

    button(dc, saves_open_rect, .saves_open_folder, false);

    if (save_slot_count == 0) {
        card(dc, .{ .left = 282, .top = 200, .right = 1086, .bottom = 268 });
        localizedText(dc, .saves_empty, .{ .left = 306, .top = 224, .right = 1062, .bottom = 248 }, 0x008b817a, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
        return;
    }

    for (save_slots[0..save_slot_count], 0..) |slot, index| {
        const top = 200 + @as(i32, @intCast(index)) * 44;
        if (top > 660) break;
        roundFill(dc, .{ .left = 282, .top = top, .right = 1086, .bottom = top + 38 }, 8, 0x00251f1b);
        text(dc, &slot.title_id, @intCast(slot.title_id_length), .{ .left = 300, .top = top + 10, .right = 410, .bottom = top + 32 }, 0x00ffac64, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
        text(dc, &slot.name, @intCast(slot.name_length), .{ .left = 425, .top = top + 9, .right = 675, .bottom = top + 32 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
        if (slot.detail_length != 0) {
            text(dc, &slot.detail, @intCast(slot.detail_length), .{ .left = 690, .top = top + 10, .right = 1066, .bottom = top + 32 }, 0x009b9088, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
        }
    }
}

fn drawSettings(dc: Win32.DeviceContext) void {
    pageHeading(dc, .settings_heading, .settings_subtitle);
    localizedText(dc, .language, .{ .left = 282, .top = 158, .right = 600, .bottom = 180 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    drawLanguageCard(dc, .english, .{ .left = 282, .top = 190, .right = 472, .bottom = 246 }, "English");
    drawLanguageCard(dc, .russian, .{ .left = 486, .top = 190, .right = 676, .bottom = 246 }, "Русский");
    drawLanguageCard(dc, .german, .{ .left = 690, .top = 190, .right = 880, .bottom = 246 }, "Deutsch");
    drawLanguageCard(dc, .french, .{ .left = 894, .top = 190, .right = 1086, .bottom = 246 }, "Français");

    card(dc, .{ .left = 282, .top = 278, .right = 1086, .bottom = 360 });
    localizedText(dc, .sound_output, .{ .left = 310, .top = 296, .right = 550, .bottom = 321 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
    localizedText(dc, .sound_output_description, .{ .left = 310, .top = 328, .right = 760, .bottom = 350 }, 0x008b817a, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    drawToggle(dc, 988, 302, sound_enabled);

    card(dc, .{ .left = 282, .top = 382, .right = 1086, .bottom = 464 });
    localizedText(dc, .fps_counter, .{ .left = 310, .top = 400, .right = 550, .bottom = 425 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
    localizedText(dc, .fps_counter_description, .{ .left = 310, .top = 432, .right = 860, .bottom = 454 }, 0x008b817a, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    drawToggle(dc, 988, 406, show_fps);

    card(dc, .{ .left = 282, .top = 486, .right = 1086, .bottom = 588 });
    localizedText(dc, .compatibility, .{ .left = 310, .top = 504, .right = 550, .bottom = 530 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
    localizedText(dc, .compatibility_text, .{ .left = 310, .top = 538, .right = 1048, .bottom = 578 }, 0x00aaa098, regular_font, Win32.dt_left | Win32.dt_word_break);

    card(dc, .{ .left = 282, .top = 610, .right = 1086, .bottom = 700 });
    text(dc, w("PS5PCEM"), -1, .{ .left = 310, .top = 627, .right = 500, .bottom = 654 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, .author, .{ .left = 310, .top = 667, .right = 840, .bottom = 691 }, 0x00ffac64, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    text(dc, w("GPL-3.0-or-later"), -1, .{ .left = 860, .top = 667, .right = 1048, .bottom = 691 }, 0x008b817a, regular_font, Win32.dt_right);
}

fn pageHeading(dc: Win32.DeviceContext, heading: Phrase, subtitle: Phrase) void {
    localizedText(dc, heading, .{ .left = 282, .top = 42, .right = 1000, .bottom = 82 }, 0x00f4f0ea, title_font, Win32.dt_left);
    localizedText(dc, subtitle, .{ .left = 282, .top = 91, .right = 1086, .bottom = 118 }, 0x009b9088, regular_font, Win32.dt_left);
    roundFill(dc, .{ .left = 984, .top = 44, .right = 1086, .bottom = 72 }, 14, 0x00342a25);
    // The label needs the pill's whole inner width. A narrower rectangle
    // centred the text and then clipped both of its ends, which read as a
    // misspelling rather than as truncation.
    text(dc, w("EARLY BUILD"), -1, .{ .left = 988, .top = 52, .right = 1082, .bottom = 68 }, 0x00ffac64, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
}

fn drawFooter(dc: Win32.DeviceContext) void {
    if (status_length == 0) return;
    text(dc, &status_text, @intCast(status_length), .{ .left = 600, .top = 124, .right = 1086, .bottom = 146 }, if (status_error) 0x006b77ff else 0x0068d391, small_font, Win32.dt_right | Win32.dt_end_ellipsis);
}

fn drawModeCard(dc: Win32.DeviceContext, mode: InputMode, rectangle: Rect, heading: Phrase, subtitle: Phrase) void {
    const selected = input_mode == mode;
    roundFill(dc, rectangle, 12, if (selected) 0x0042362e else 0x00251f1b);
    if (selected) roundFill(dc, .{ .left = rectangle.left + 14, .top = rectangle.top + 16, .right = rectangle.left + 24, .bottom = rectangle.top + 26 }, 5, 0x00ffac64);
    localizedText(dc, heading, .{ .left = rectangle.left + 36, .top = rectangle.top + 13, .right = rectangle.right - 12, .bottom = rectangle.top + 38 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, subtitle, .{ .left = rectangle.left + 36, .top = rectangle.top + 44, .right = rectangle.right - 12, .bottom = rectangle.top + 66 }, 0x008b817a, small_font, Win32.dt_left);
}

fn drawLanguageCard(dc: Win32.DeviceContext, value: Language, rectangle: Rect, label: []const u8) void {
    const selected = language == value;
    roundFill(dc, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
    if (selected) roundFill(dc, .{ .left = rectangle.left + 14, .top = rectangle.top + 23, .right = rectangle.left + 24, .bottom = rectangle.top + 33 }, 5, 0x00ffac64);
    textUtf8(dc, label, .{ .left = rectangle.left + 36, .top = rectangle.top + 18, .right = rectangle.right - 12, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, medium_font, Win32.dt_left);
}

fn card(dc: Win32.DeviceContext, rectangle: Rect) void {
    roundFill(dc, rectangle, 14, 0x00251f1b);
}

fn button(dc: Win32.DeviceContext, rectangle: Rect, label: Phrase, disabled: bool) void {
    roundFill(dc, rectangle, 10, if (disabled) 0x00352c27 else 0x00ff9c3d);
    localizedText(dc, label, .{ .left = rectangle.left + 12, .top = rectangle.top + 14, .right = rectangle.right - 12, .bottom = rectangle.bottom - 8 }, if (disabled) 0x007d736c else 0x00181510, medium_font, Win32.dt_center);
}

fn drawToggle(dc: Win32.DeviceContext, x: i32, y: i32, enabled: bool) void {
    roundFill(dc, .{ .left = x, .top = y, .right = x + 58, .bottom = y + 30 }, 15, if (enabled) 0x00ff9c3d else 0x00483d36);
    const knob_x = if (enabled) x + 32 else x + 4;
    roundFill(dc, .{ .left = knob_x, .top = y + 4, .right = knob_x + 22, .bottom = y + 26 }, 11, 0x00fffaf5);
}

fn fill(dc: Win32.DeviceContext, rectangle: Rect, color: u32) void {
    const brush = Win32.CreateSolidBrush(color) orelse return;
    defer _ = Win32.DeleteObject(brush);
    var native = Win32.NativeRect{ .left = rectangle.left, .top = rectangle.top, .right = rectangle.right, .bottom = rectangle.bottom };
    _ = Win32.FillRect(dc, &native, brush);
}

fn roundFill(dc: Win32.DeviceContext, rectangle: Rect, radius: i32, color: u32) void {
    const brush = Win32.CreateSolidBrush(color) orelse return;
    defer _ = Win32.DeleteObject(brush);
    const old_brush = Win32.SelectObject(dc, brush);
    const old_pen = Win32.SelectObject(dc, Win32.GetStockObject(Win32.null_pen));
    _ = Win32.RoundRect(dc, rectangle.left, rectangle.top, rectangle.right, rectangle.bottom, radius, radius);
    _ = Win32.SelectObject(dc, old_brush);
    _ = Win32.SelectObject(dc, old_pen);
}

fn drawBitmap(dc: Win32.DeviceContext, bitmap: Win32.Bitmap, rectangle: Rect) void {
    const memory_dc = Win32.CreateCompatibleDC(dc) orelse return;
    defer _ = Win32.DeleteDC(memory_dc);
    const previous = Win32.SelectObject(memory_dc, bitmap);
    _ = Win32.SetStretchBltMode(dc, Win32.halftone);
    _ = Win32.StretchBlt(
        dc,
        rectangle.left,
        rectangle.top,
        rectangle.right - rectangle.left,
        rectangle.bottom - rectangle.top,
        memory_dc,
        0,
        0,
        136,
        136,
        Win32.source_copy,
    );
    _ = Win32.SelectObject(memory_dc, previous);
}

fn text(
    dc: Win32.DeviceContext,
    value: [*]const u16,
    length: i32,
    rectangle: Rect,
    color: u32,
    font: Win32.Font,
    format: u32,
) void {
    _ = Win32.SetBkMode(dc, Win32.transparent);
    _ = Win32.SetTextColor(dc, color);
    const previous = Win32.SelectObject(dc, font);
    var native = Win32.NativeRect{ .left = rectangle.left, .top = rectangle.top, .right = rectangle.right, .bottom = rectangle.bottom };
    _ = Win32.DrawTextW(dc, value, length, &native, format | Win32.dt_no_prefix);
    _ = Win32.SelectObject(dc, previous);
}

fn textUtf8(dc: Win32.DeviceContext, value: []const u8, rectangle: Rect, color: u32, font: Win32.Font, format: u32) void {
    var buffer: [512]u16 = undefined;
    const converted = std.unicode.utf8ToUtf16Le(&buffer, value) catch return;
    text(dc, &buffer, @intCast(converted), rectangle, color, font, format);
}

fn localizedText(dc: Win32.DeviceContext, phrase: Phrase, rectangle: Rect, color: u32, font: Win32.Font, format: u32) void {
    textUtf8(dc, tr(phrase), rectangle, color, font, format);
}

fn chooseGameFolder(owner: Win32.Window) void {
    var display: [1024]u16 = [_]u16{0} ** 1024;
    var dialog_title: [256]u16 = [_]u16{0} ** 256;
    const dialog_title_length = std.unicode.utf8ToUtf16Le(&dialog_title, tr(.browse_dialog)) catch return;
    dialog_title[dialog_title_length] = 0;
    var browse = Win32.BrowseInfoW{
        .owner = owner,
        .root = null,
        .display_name = &display,
        .title = @ptrCast(&dialog_title),
        .flags = Win32.bif_return_only_fs_dirs | Win32.bif_new_dialog_style,
        .callback = null,
        .l_param = 0,
        .image = 0,
    };
    const item = Win32.SHBrowseForFolderW(&browse) orelse return;
    defer Win32.CoTaskMemFree(item);
    if (Win32.SHGetPathFromIDListW(item, &game_folder) == 0) return;
    game_folder_length = wideLength(@ptrCast(&game_folder));
    refreshTitleIdentifier();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    saveSettings();
    setStatusPhrase(.status_folder_selected, false);
}

fn launchGame(owner: Win32.Window) void {
    if (game_folder_length == 0) {
        setStatusPhrase(.status_choose_folder, true);
        return;
    }
    var executable: [1024]u16 = [_]u16{0} ** 1024;
    if (!findGameExecutable(&executable)) {
        setStatusPhrase(.status_eboot_missing, true);
        return;
    }

    var runner: [1024]u16 = [_]u16{0} ** 1024;
    const runner_len = siblingExecutable("game-run.exe", &runner);
    if (runner_len == 0 or Win32.GetFileAttributesW(@ptrCast(&runner)) == Win32.invalid_file_attributes) {
        setStatusPhrase(.status_runner_missing, true);
        return;
    }

    _ = Win32.SetEnvironmentVariableW(w("PS5_AUDIO_DISABLED"), if (sound_enabled) null else w("1"));
    _ = Win32.SetEnvironmentVariableW(w("PS5_SHOW_FPS"), if (show_fps) w("1") else null);
    _ = Win32.SetEnvironmentVariableW(w("PS5_INPUT_MODE"), inputModeEnvironment());
    var controller_value = [_:0]u16{@as(u16, '0') + controller_index};
    _ = Win32.SetEnvironmentVariableW(w("PS5_CONTROLLER_INDEX"), &controller_value);
    var keymap: [512]u16 = [_]u16{0} ** 512;
    buildKeymap(&keymap);
    _ = Win32.SetEnvironmentVariableW(w("PS5_KEYMAP"), @ptrCast(&keymap));

    var command: [4096]u16 = [_]u16{0} ** 4096;
    var length: usize = 0;
    appendWide(&command, &length, w("\""));
    appendWideSlice(&command, &length, runner[0..runner_len]);
    appendWide(&command, &length, w("\" --app0 \""));
    appendWideSlice(&command, &length, game_folder[0..game_folder_length]);
    appendWide(&command, &length, w("\" \""));
    appendWideSlice(&command, &length, executable[0..wideLength(@ptrCast(&executable))]);
    appendWide(&command, &length, w("\""));
    command[length] = 0;

    var startup = Win32.StartupInfoW{ .size = @sizeOf(Win32.StartupInfoW) };
    var process: Win32.ProcessInformation = undefined;
    var emulator_home: [1024]u16 = @splat(0);
    if (emulatorHomeDirectory(&emulator_home) == 0) {
        setStatusPhrase(.status_launch_failed, true);
        return;
    }
    if (Win32.CreateProcessW(
        @ptrCast(&runner),
        @ptrCast(&command),
        null,
        null,
        0,
        Win32.create_new_console,
        null,
        @ptrCast(&emulator_home),
        &startup,
        &process,
    ) == 0) {
        setStatusPhrase(.status_launch_failed, true);
        return;
    }
    _ = Win32.CloseHandle(process.thread);
    _ = Win32.CloseHandle(process.process);
    rememberGameFolder(game_folder[0..game_folder_length], true);
    setStatusPhrase(.status_launched, false);
    _ = Win32.ShowWindow(owner, Win32.show_minimized);
}

fn findGameExecutable(output: *[1024]u16) bool {
    const suffixes = [_][]const u8{ "\\eboot.bin", "\\decrypted\\eboot.bin", "\\sce_sys\\eboot.bin" };
    for (suffixes) |suffix| {
        @memset(output, 0);
        @memcpy(output[0..game_folder_length], game_folder[0..game_folder_length]);
        var length = game_folder_length;
        var converted: [64]u16 = undefined;
        const suffix_length = std.unicode.utf8ToUtf16Le(&converted, suffix) catch continue;
        @memcpy(output[length..][0..suffix_length], converted[0..suffix_length]);
        length += suffix_length;
        output[length] = 0;
        if (Win32.GetFileAttributesW(@ptrCast(output)) != Win32.invalid_file_attributes) return true;
    }
    return false;
}

fn openGithub(owner: Win32.Window) void {
    _ = Win32.ShellExecuteW(owner, w("open"), w(github_url), null, null, Win32.show_normal);
}

fn openBoosty(owner: Win32.Window) void {
    _ = Win32.ShellExecuteW(owner, w("open"), w(boosty_url), null, null, Win32.show_normal);
}

fn inputModeTitle() Phrase {
    return switch (input_mode) {
        .controller => .gamepad,
        .keyboard => .keyboard_dualsense,
        .hybrid => .gamepad_keyboard,
    };
}

fn inputModeDescription() Phrase {
    return switch (input_mode) {
        .controller => .controller_description,
        .keyboard => .keyboard_description,
        .hybrid => .hybrid_description,
    };
}

fn inputModeEnvironment() [*:0]const u16 {
    return switch (input_mode) {
        .controller => w("controller"),
        .keyboard => w("keyboard"),
        .hybrid => w("hybrid"),
    };
}

fn buildKeymap(output: *[512]u16) void {
    const names = [_][]const u8{ "cross", "circle", "square", "triangle", "l1", "l2", "r1", "r2", "options", "touch", "up", "right", "down", "left" };
    var utf8: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    for (names, mapping, 0..) |name, key, index| {
        if (index != 0) stream.writeByte(',') catch return;
        stream.print("{s}={d}", .{ name, key }) catch return;
    }
    const converted = std.unicode.utf8ToUtf16Le(output, stream.buffered()) catch return;
    output[converted] = 0;
}

fn setStatus(value: []const u8, is_error: bool) void {
    @memset(&status_text, 0);
    const converted = std.unicode.utf8ToUtf16Le(&status_text, value) catch return;
    status_length = converted;
    status_error = is_error;
}

fn setStatusPhrase(phrase: Phrase, is_error: bool) void {
    setStatus(tr(phrase), is_error);
}

fn initializeIniPath() void {
    ini_path_length = Win32.GetModuleFileNameW(null, &ini_path, ini_path.len);
    if (ini_path_length == 0 or ini_path_length >= ini_path.len) return;
    while (ini_path_length > 0 and ini_path[ini_path_length - 1] != '\\') : (ini_path_length -= 1) {}
    const name = w("ps5pcem.ini");
    const name_length = wideLength(name);
    if (ini_path_length + name_length >= ini_path.len) return;
    @memcpy(ini_path[ini_path_length..][0..name_length], name[0..name_length]);
    ini_path_length += name_length;
    ini_path[ini_path_length] = 0;
}

fn siblingExecutable(comptime name: []const u8, output: *[1024]u16) usize {
    var length: usize = Win32.GetModuleFileNameW(null, output, output.len);
    if (length == 0 or length >= output.len) return 0;
    while (length > 0 and output[length - 1] != '\\') : (length -= 1) {}
    const file_name = w(name);
    const file_length = wideLength(file_name);
    if (length + file_length >= output.len) return 0;
    @memcpy(output[length..][0..file_length], file_name[0..file_length]);
    length += file_length;
    output[length] = 0;
    return length;
}

fn loadSettings() void {
    if (ini_path_length == 0) return;
    loadRecentGames();
    game_folder_length = Win32.GetPrivateProfileStringW(w("launcher"), w("game_folder"), w(""), &game_folder, game_folder.len, @ptrCast(&ini_path));
    refreshTitleIdentifier();
    if (game_folder_length != 0) rememberGameFolder(game_folder[0..game_folder_length], true);
    sound_enabled = Win32.GetPrivateProfileIntW(w("launcher"), w("sound"), 1, @ptrCast(&ini_path)) != 0;
    show_fps = Win32.GetPrivateProfileIntW(w("launcher"), w("show_fps"), 0, @ptrCast(&ini_path)) != 0;
    const mode_value = Win32.GetPrivateProfileIntW(w("launcher"), w("input_mode"), 2, @ptrCast(&ini_path));
    if (mode_value <= 2) input_mode = @enumFromInt(mode_value);
    const language_value = Win32.GetPrivateProfileIntW(w("launcher"), w("language"), 0, @ptrCast(&ini_path));
    if (language_value <= 3) language = @enumFromInt(language_value);
    const controller_value = Win32.GetPrivateProfileIntW(w("launcher"), w("controller_index"), 0, @ptrCast(&ini_path));
    if (controller_value <= 3) controller_index = @intCast(controller_value);
    for (0..mapping.len) |index| {
        var key_name: [32]u16 = [_]u16{0} ** 32;
        keyName(index, &key_name);
        const value = Win32.GetPrivateProfileIntW(w("keymap"), @ptrCast(&key_name), mapping_defaults[index], @ptrCast(&ini_path));
        if (value < 256) mapping[index] = @intCast(value);
    }
}

fn saveSettings() void {
    if (ini_path_length == 0) return;
    _ = Win32.WritePrivateProfileStringW(w("launcher"), w("game_folder"), @ptrCast(&game_folder), @ptrCast(&ini_path));
    writeIniInt(w("launcher"), w("sound"), @intFromBool(sound_enabled));
    writeIniInt(w("launcher"), w("show_fps"), @intFromBool(show_fps));
    writeIniInt(w("launcher"), w("input_mode"), @intFromEnum(input_mode));
    writeIniInt(w("launcher"), w("language"), @intFromEnum(language));
    writeIniInt(w("launcher"), w("controller_index"), controller_index);
    for (0..mapping.len) |index| {
        var name: [32]u16 = [_]u16{0} ** 32;
        keyName(index, &name);
        writeIniInt(w("keymap"), @ptrCast(&name), mapping[index]);
    }
}

fn keyName(index: usize, output: *[32]u16) void {
    var utf8: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    stream.print("key_{d}", .{index}) catch return;
    const converted = std.unicode.utf8ToUtf16Le(output, stream.buffered()) catch return;
    output[converted] = 0;
}

fn writeIniInt(section: [*:0]const u16, name: [*:0]const u16, value: u32) void {
    var utf8: [24]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    stream.print("{d}", .{value}) catch return;
    var wide: [24]u16 = [_]u16{0} ** 24;
    const converted = std.unicode.utf8ToUtf16Le(&wide, stream.buffered()) catch return;
    wide[converted] = 0;
    _ = Win32.WritePrivateProfileStringW(section, name, @ptrCast(&wide), @ptrCast(&ini_path));
}

fn keyDisplayName(key: u8, output: *[48]u16) usize {
    const scan = Win32.MapVirtualKeyW(key, 0);
    const extended: u32 = if (key >= 0x21 and key <= 0x2e) 1 << 24 else 0;
    const length = Win32.GetKeyNameTextW(@bitCast((scan << 16) | extended), output, output.len);
    if (length > 0) return @intCast(length);
    const fallback = w("Key");
    const fallback_length = wideLength(fallback);
    @memcpy(output[0..fallback_length], fallback[0..fallback_length]);
    return fallback_length;
}

fn createFonts() void {
    regular_font = Win32.CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
    medium_font = Win32.CreateFontW(-17, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
    title_font = Win32.CreateFontW(-27, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
    small_font = Win32.CreateFontW(-13, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
}

fn destroyFonts() void {
    if (regular_font != null) _ = Win32.DeleteObject(regular_font);
    if (medium_font != null) _ = Win32.DeleteObject(medium_font);
    if (title_font != null) _ = Win32.DeleteObject(title_font);
    if (small_font != null) _ = Win32.DeleteObject(small_font);
}

fn appendWide(output: *[4096]u16, length: *usize, value: [*:0]const u16) void {
    appendWideSlice(output, length, value[0..wideLength(value)]);
}

fn appendWideSlice(output: *[4096]u16, length: *usize, value: []const u16) void {
    if (length.* + value.len >= output.len) return;
    @memcpy(output[length.*..][0..value.len], value);
    length.* += value.len;
}

fn wideLength(value: [*:0]const u16) usize {
    var length: usize = 0;
    while (value[length] != 0) : (length += 1) {}
    return length;
}

fn w(comptime value: []const u8) [*:0]const u16 {
    @setEvalBranchQuota(20_000);
    return std.unicode.utf8ToUtf16LeStringLiteral(value);
}

const Win32 = if (builtin.os.tag == .windows) struct {
    const Window = ?*anyopaque;
    const Instance = ?*anyopaque;
    const Icon = ?*anyopaque;
    const Cursor = ?*anyopaque;
    const Brush = ?*anyopaque;
    const Font = ?*anyopaque;
    const Bitmap = ?*anyopaque;
    const DeviceContext = ?*anyopaque;
    const Menu = ?*anyopaque;
    const Object = ?*anyopaque;
    const Handle = ?*anyopaque;

    const Point = extern struct { x: i32, y: i32 };
    const GdiPlusImage = ?*anyopaque;
    const GdiplusStartupInput = extern struct {
        version: u32 = 1,
        debug_event_callback: ?*const anyopaque = null,
        suppress_background_thread: i32 = 0,
        suppress_external_codecs: i32 = 0,
    };
    const NativeRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    const Message = extern struct {
        window: Window,
        message: u32,
        word_parameter: usize,
        long_parameter: isize,
        time: u32,
        point: Point,
        private: u32,
    };
    const TrackMouseEventData = extern struct {
        size: u32,
        flags: u32,
        window: Window,
        hover_time: u32,
    };
    const PaintStruct = extern struct {
        dc: DeviceContext,
        erase: i32,
        paint: NativeRect,
        restore: i32,
        inc_update: i32,
        reserved: [32]u8,
    };
    const WindowProcedure = *const fn (Window, u32, usize, isize) callconv(.winapi) isize;
    const WndClassExW = extern struct {
        size: u32,
        style: u32,
        window_procedure: WindowProcedure,
        class_extra: i32,
        window_extra: i32,
        instance: Instance,
        icon: Icon,
        cursor: Cursor,
        background: Brush,
        menu_name: ?[*:0]const u16,
        class_name: [*:0]const u16,
        small_icon: Icon,
    };
    const BrowseInfoW = extern struct {
        owner: Window,
        root: ?*anyopaque,
        display_name: [*]u16,
        title: [*:0]const u16,
        flags: u32,
        callback: ?*const anyopaque,
        l_param: isize,
        image: i32,
    };
    const StartupInfoW = extern struct {
        size: u32 = 0,
        reserved: ?[*]u16 = null,
        desktop: ?[*]u16 = null,
        title: ?[*]u16 = null,
        x: u32 = 0,
        y: u32 = 0,
        x_size: u32 = 0,
        y_size: u32 = 0,
        x_count_chars: u32 = 0,
        y_count_chars: u32 = 0,
        fill_attribute: u32 = 0,
        flags: u32 = 0,
        show_window: u16 = 0,
        reserved2_size: u16 = 0,
        reserved2: ?[*]u8 = null,
        std_input: Handle = null,
        std_output: Handle = null,
        std_error: Handle = null,
    };
    const ProcessInformation = extern struct {
        process: Handle,
        thread: Handle,
        process_id: u32,
        thread_id: u32,
    };

    const class_redraw: u32 = 0x0001 | 0x0002;
    const window_style: u32 = 0x00c0_0000 | 0x0008_0000 | 0x0002_0000 | 0x0001_0000;
    const centered: i32 = @bitCast(@as(u32, 0x8000_0000));
    const show_normal: i32 = 5;
    const show_minimized: i32 = 2;
    const wm_destroy: u32 = 0x0002;
    const wm_paint: u32 = 0x000f;
    const wm_close: u32 = 0x0010;
    const wm_erase_background: u32 = 0x0014;
    const wm_timer: u32 = 0x0113;
    const wm_mouse_move: u32 = 0x0200;
    const wm_mouse_leave: u32 = 0x02a3;
    const wm_device_change: u32 = 0x0219;
    const hit_test_client: u16 = 1;
    const wm_set_cursor: u32 = 0x0020;
    // IDC_HAND is an odd numeric identifier passed in a pointer slot, so it
    // cannot carry the alignment a real UTF-16 string would.
    const hand_cursor: [*:0]align(1) const u16 = @ptrFromInt(32649);
    const app_icon_resource: [*:0]align(1) const u16 = @ptrFromInt(1);
    const wm_key_down: u32 = 0x0100;
    const wm_left_button_up: u32 = 0x0202;
    const tme_leave: u32 = 0x0000_0002;
    const transparent: i32 = 1;
    const dt_left: u32 = 0x0000;
    const dt_center: u32 = 0x0001;
    const dt_right: u32 = 0x0002;
    const dt_word_break: u32 = 0x0010;
    const dt_no_prefix: u32 = 0x0800;
    const dt_end_ellipsis: u32 = 0x8000;
    const di_normal: u32 = 0x0003;
    const null_pen: i32 = 8;
    const arrow_cursor: [*:0]const u16 = @ptrFromInt(32512);
    const NativePoint = extern struct { x: i32 = 0, y: i32 = 0 };

    const FindData = extern struct {
        attributes: u32 = 0,
        creation_time: [2]u32 = .{ 0, 0 },
        access_time: [2]u32 = .{ 0, 0 },
        write_time: [2]u32 = .{ 0, 0 },
        size_high: u32 = 0,
        size_low: u32 = 0,
        reserved: [2]u32 = .{ 0, 0 },
        name: [260]u16 = @splat(0),
        alternate_name: [14]u16 = @splat(0),
    };

    const file_attribute_directory: u32 = 0x10;
    const generic_read: u32 = 0x8000_0000;
    const file_share_read: u32 = 0x0000_0001;
    const open_existing: u32 = 3;
    const invalid_handle: usize = std.math.maxInt(usize);
    const error_class_already_exists: u32 = 1410;
    const bif_return_only_fs_dirs: u32 = 0x0001;
    const bif_new_dialog_style: u32 = 0x0040;
    const coinit_apartment_threaded: u32 = 0x0002;
    const invalid_file_attributes: u32 = 0xffff_ffff;
    const create_new_console: u32 = 0x0000_0010;
    const cstr_equal: i32 = 2;
    const halftone: i32 = 4;
    const source_copy: u32 = 0x00cc_0020;
    const dpi_awareness_per_monitor_v2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) Instance;
    extern "kernel32" fn GetModuleFileNameW(module: Instance, output: [*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn CreateProcessW(application: ?[*:0]const u16, command: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: i32, flags: u32, environment: ?*anyopaque, directory: ?[*:0]const u16, startup: *StartupInfoW, process: *ProcessInformation) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
    extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, i32) callconv(.winapi) i32;
    extern "kernel32" fn GetPrivateProfileStringW(section: [*:0]const u16, key: [*:0]const u16, default: [*:0]const u16, output: [*]u16, size: u32, file: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetPrivateProfileIntW(section: [*:0]const u16, key: [*:0]const u16, default: u32, file: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn WritePrivateProfileStringW(section: [*:0]const u16, key: [*:0]const u16, value: ?[*:0]const u16, file: [*:0]const u16) callconv(.winapi) i32;

    extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(extended_style: u32, class_name: [*:0]const u16, window_name: [*:0]const u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: Window, menu: Menu, instance: Instance, parameter: ?*anyopaque) callconv(.winapi) Window;
    extern "user32" fn DefWindowProcW(Window, u32, usize, isize) callconv(.winapi) isize;
    extern "user32" fn DestroyWindow(Window) callconv(.winapi) i32;
    extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
    extern "user32" fn ShowWindow(Window, i32) callconv(.winapi) i32;
    extern "user32" fn UpdateWindow(Window) callconv(.winapi) i32;
    extern "user32" fn GetMessageW(*Message, Window, u32, u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(*const Message) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(*const Message) callconv(.winapi) isize;
    extern "user32" fn LoadCursorW(Instance, [*:0]align(1) const u16) callconv(.winapi) Cursor;
    extern "user32" fn SetCursor(Cursor) callconv(.winapi) Cursor;
    extern "user32" fn AdjustWindowRect(*NativeRect, u32, i32) callconv(.winapi) i32;
    extern "user32" fn SetTimer(Window, usize, u32, ?*anyopaque) callconv(.winapi) usize;
    extern "user32" fn KillTimer(Window, usize) callconv(.winapi) i32;
    extern "user32" fn TrackMouseEvent(*TrackMouseEventData) callconv(.winapi) i32;
    extern "kernel32" fn FindFirstFileW([*:0]const u16, *FindData) callconv(.winapi) *anyopaque;
    extern "kernel32" fn FindNextFileW(*anyopaque, *FindData) callconv(.winapi) i32;
    extern "kernel32" fn FindClose(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) Handle;
    extern "kernel32" fn ReadFile(Handle, [*]u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn GetCursorPos(*NativePoint) callconv(.winapi) i32;
    extern "user32" fn ScreenToClient(Window, *NativePoint) callconv(.winapi) i32;
    extern "user32" fn LoadIconW(Instance, ?[*:0]align(1) const u16) callconv(.winapi) Icon;
    extern "user32" fn BeginPaint(Window, *PaintStruct) callconv(.winapi) DeviceContext;
    extern "user32" fn EndPaint(Window, *const PaintStruct) callconv(.winapi) i32;
    extern "user32" fn GetClientRect(Window, *NativeRect) callconv(.winapi) i32;
    extern "user32" fn FillRect(DeviceContext, *const NativeRect, Brush) callconv(.winapi) i32;
    extern "user32" fn DrawTextW(DeviceContext, [*]const u16, i32, *NativeRect, u32) callconv(.winapi) i32;
    extern "user32" fn DrawIconEx(DeviceContext, i32, i32, Icon, i32, i32, u32, Brush, u32) callconv(.winapi) i32;
    extern "user32" fn InvalidateRect(Window, ?*const NativeRect, i32) callconv(.winapi) i32;
    extern "user32" fn SetProcessDpiAwarenessContext(?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
    extern "user32" fn GetKeyNameTextW(long_parameter: i32, output: [*]u16, size: i32) callconv(.winapi) i32;

    extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) Brush;
    extern "gdi32" fn CreateCompatibleDC(DeviceContext) callconv(.winapi) DeviceContext;
    extern "gdi32" fn DeleteDC(DeviceContext) callconv(.winapi) i32;
    extern "gdi32" fn SetStretchBltMode(DeviceContext, i32) callconv(.winapi) i32;
    extern "gdi32" fn StretchBlt(DeviceContext, i32, i32, i32, i32, DeviceContext, i32, i32, i32, i32, u32) callconv(.winapi) i32;
    extern "gdi32" fn DeleteObject(Object) callconv(.winapi) i32;
    extern "gdi32" fn SelectObject(DeviceContext, Object) callconv(.winapi) Object;
    extern "gdi32" fn GetStockObject(i32) callconv(.winapi) Object;
    extern "gdi32" fn RoundRect(DeviceContext, i32, i32, i32, i32, i32, i32) callconv(.winapi) i32;
    extern "gdi32" fn SetBkMode(DeviceContext, i32) callconv(.winapi) i32;
    extern "gdi32" fn SetTextColor(DeviceContext, u32) callconv(.winapi) u32;
    extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) Font;

    extern "gdiplus" fn GdiplusStartup(*usize, *const GdiplusStartupInput, ?*anyopaque) callconv(.winapi) i32;
    extern "gdiplus" fn GdiplusShutdown(usize) callconv(.winapi) void;
    extern "gdiplus" fn GdipCreateBitmapFromFile([*:0]const u16, *GdiPlusImage) callconv(.winapi) i32;
    extern "gdiplus" fn GdipGetImageThumbnail(GdiPlusImage, u32, u32, *GdiPlusImage, ?*const anyopaque, ?*anyopaque) callconv(.winapi) i32;
    extern "gdiplus" fn GdipCreateHBITMAPFromBitmap(GdiPlusImage, *Bitmap, u32) callconv(.winapi) i32;
    extern "gdiplus" fn GdipDisposeImage(GdiPlusImage) callconv(.winapi) i32;

    extern "shell32" fn SHBrowseForFolderW(*BrowseInfoW) callconv(.winapi) ?*anyopaque;
    extern "shell32" fn SHGetPathFromIDListW(?*anyopaque, [*]u16) callconv(.winapi) i32;
    extern "shell32" fn ShellExecuteW(Window, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) Handle;
    extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
    extern "dwmapi" fn DwmSetWindowAttribute(Window, u32, *const anyopaque, u32) callconv(.winapi) i32;
} else struct {};
