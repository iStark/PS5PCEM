// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Native Windows launcher for PS5PCEM.
//!
//! The interface deliberately uses only Win32/GDI so the emulator keeps its
//! zero-dependency build. Settings are persisted next to the executable and
//! passed to game-run through its small environment contract.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // The interface contains a fair amount of Cyrillic text converted to
    // UTF-16 at compile time.
    @setEvalBranchQuota(20_000);
}

const github_url = "https://github.com/iStark/PS5PCEM";
const window_width = 1180;
const window_height = 760;
const sidebar_width = 222;

const Page = enum { library, input, settings };
const InputMode = enum(u8) { controller = 0, keyboard = 1, hybrid = 2 };
const Language = enum(u8) { english = 0, russian = 1, german = 2, french = 3 };

const Phrase = enum {
    nav_library,
    nav_input,
    nav_settings,
    project,
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
    compatibility,
    compatibility_text,
    author,
    browse_dialog,
    status_layout_saved,
    status_press_key,
    status_input_saved,
    status_controller_saved,
    status_sound_on,
    status_sound_off,
    status_folder_selected,
    status_choose_folder,
    status_eboot_missing,
    status_runner_missing,
    status_launch_failed,
    status_launched,
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
var sound_enabled = true;
var mapping = mapping_defaults;
var capture_mapping: ?usize = null;
var game_folder: [1024]u16 = [_]u16{0} ** 1024;
var game_folder_length: usize = 0;
var status_text: [256]u16 = [_]u16{0} ** 256;
var status_length: usize = 0;
var status_error = false;
var ini_path: [1024]u16 = [_]u16{0} ** 1024;
var ini_path_length: usize = 0;
var regular_font: Win32.Font = null;
var medium_font: Win32.Font = null;
var title_font: Win32.Font = null;
var small_font: Win32.Font = null;

fn tr(phrase: Phrase) []const u8 {
    return switch (language) {
        .english => switch (phrase) {
            .nav_library => "Library",
            .nav_input => "Controls",
            .nav_settings => "Settings",
            .project => "PROJECT",
            .library_heading => "Game library",
            .library_subtitle => "Choose a local folder containing a decrypted copy of your game",
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
            .compatibility => "Compatibility",
            .compatibility_text => "PS5PCEM is at an early stage. Not every title boots yet; advanced DualSense features, native PS5 keyboard/mouse and controller-to-keyboard conversion still need more HLE support.",
            .author => "Author: Artur Strazewicz · GitHub: iStark/PS5PCEM",
            .browse_dialog => "Choose the folder containing a decrypted PS5 game",
            .status_layout_saved => "Keyboard bindings saved",
            .status_press_key => "Press a new key · Esc to cancel",
            .status_input_saved => "Input profile saved",
            .status_controller_saved => "Controller slot saved",
            .status_sound_on => "Sound enabled",
            .status_sound_off => "Sound disabled",
            .status_folder_selected => "Folder selected · ready to launch",
            .status_choose_folder => "Choose a game folder first",
            .status_eboot_missing => "eboot.bin was not found in the selected folder or decrypted subfolder",
            .status_runner_missing => "game-run.exe was not found · run zig build first",
            .status_launch_failed => "Could not start game-run.exe",
            .status_launched => "Game launched in a separate process",
        },
        .russian => switch (phrase) {
            .nav_library => "Библиотека",
            .nav_input => "Управление",
            .nav_settings => "Настройки",
            .project => "ПРОЕКТ",
            .library_heading => "Игровая библиотека",
            .library_subtitle => "Выберите локальную папку с расшифрованной копией игры",
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
            .compatibility => "Совместимость",
            .compatibility_text => "PS5PCEM находится на ранней стадии. Не все игры загружаются; функции DualSense, нативные PS5-клавиатура/мышь и преобразование геймпада в клавиши требуют дальнейшей HLE-поддержки.",
            .author => "Автор: Artur Strazewicz · GitHub: iStark/PS5PCEM",
            .browse_dialog => "Выберите папку с расшифрованной игрой PS5",
            .status_layout_saved => "Раскладка сохранена",
            .status_press_key => "Нажмите новую клавишу · Esc — отмена",
            .status_input_saved => "Профиль ввода сохранён",
            .status_controller_saved => "Слот контроллера сохранён",
            .status_sound_on => "Звук включён",
            .status_sound_off => "Звук выключен",
            .status_folder_selected => "Папка выбрана · готово к запуску",
            .status_choose_folder => "Сначала выберите папку с игрой",
            .status_eboot_missing => "В выбранной папке не найден eboot.bin (проверены корень и decrypted)",
            .status_runner_missing => "Не найден game-run.exe · сначала выполните zig build",
            .status_launch_failed => "Не удалось запустить game-run.exe",
            .status_launched => "Игра запущена в отдельном процессе",
        },
        .german => switch (phrase) {
            .nav_library => "Bibliothek",
            .nav_input => "Steuerung",
            .nav_settings => "Einstellungen",
            .project => "PROJEKT",
            .library_heading => "Spielebibliothek",
            .library_subtitle => "Wähle einen lokalen Ordner mit einer entschlüsselten Spielkopie",
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
            .compatibility => "Kompatibilität",
            .compatibility_text => "PS5PCEM ist in einer frühen Phase. Nicht jedes Spiel startet; erweiterte DualSense-Funktionen, native PS5-Tastatur/Maus und Controller-zu-Tastatur benötigen weitere HLE-Unterstützung.",
            .author => "Autor: Artur Strazewicz · GitHub: iStark/PS5PCEM",
            .browse_dialog => "Ordner mit dem entschlüsselten PS5-Spiel wählen",
            .status_layout_saved => "Tastenbelegung gespeichert",
            .status_press_key => "Neue Taste drücken · Esc zum Abbrechen",
            .status_input_saved => "Eingabeprofil gespeichert",
            .status_controller_saved => "Controller-Slot gespeichert",
            .status_sound_on => "Ton eingeschaltet",
            .status_sound_off => "Ton ausgeschaltet",
            .status_folder_selected => "Ordner gewählt · startbereit",
            .status_choose_folder => "Zuerst einen Spielordner wählen",
            .status_eboot_missing => "eboot.bin wurde im Ordner und Unterordner decrypted nicht gefunden",
            .status_runner_missing => "game-run.exe fehlt · zuerst zig build ausführen",
            .status_launch_failed => "game-run.exe konnte nicht gestartet werden",
            .status_launched => "Spiel in einem separaten Prozess gestartet",
        },
        .french => switch (phrase) {
            .nav_library => "Bibliothèque",
            .nav_input => "Commandes",
            .nav_settings => "Paramètres",
            .project => "PROJET",
            .library_heading => "Bibliothèque de jeux",
            .library_subtitle => "Choisissez un dossier local contenant une copie déchiffrée du jeu",
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
            .compatibility => "Compatibilité",
            .compatibility_text => "PS5PCEM est encore expérimental. Tous les jeux ne démarrent pas ; les fonctions DualSense avancées, le clavier/souris PS5 natif et la conversion manette-clavier demandent davantage de prise en charge HLE.",
            .author => "Auteur : Artur Strazewicz · GitHub : iStark/PS5PCEM",
            .browse_dialog => "Choisissez le dossier du jeu PS5 déchiffré",
            .status_layout_saved => "Affectation des touches enregistrée",
            .status_press_key => "Pressez une nouvelle touche · Échap pour annuler",
            .status_input_saved => "Profil d'entrée enregistré",
            .status_controller_saved => "Emplacement de manette enregistré",
            .status_sound_on => "Son activé",
            .status_sound_off => "Son désactivé",
            .status_folder_selected => "Dossier sélectionné · prêt à lancer",
            .status_choose_folder => "Choisissez d'abord un dossier de jeu",
            .status_eboot_missing => "eboot.bin est introuvable dans le dossier ou le sous-dossier decrypted",
            .status_runner_missing => "game-run.exe est introuvable · exécutez d'abord zig build",
            .status_launch_failed => "Impossible de lancer game-run.exe",
            .status_launched => "Jeu lancé dans un processus séparé",
        },
    };
}

pub fn main(_: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    _ = Win32.SetProcessDpiAwarenessContext(Win32.dpi_awareness_per_monitor_v2);
    _ = Win32.CoInitializeEx(null, Win32.coinit_apartment_threaded);
    defer Win32.CoUninitialize();

    initializeIniPath();
    loadSettings();
    createFonts();
    defer destroyFonts();

    const instance = Win32.GetModuleHandleW(null) orelse return error.WindowCreationFailed;
    const class = Win32.WndClassExW{
        .size = @sizeOf(Win32.WndClassExW),
        .style = Win32.class_redraw,
        .window_procedure = windowProcedure,
        .class_extra = 0,
        .window_extra = 0,
        .instance = instance,
        .icon = Win32.LoadIconW(instance, null),
        .cursor = Win32.LoadCursorW(null, Win32.arrow_cursor),
        .background = null,
        .menu_name = null,
        .class_name = w("PS5PCEM_LAUNCHER"),
        .small_icon = null,
    };
    if (Win32.RegisterClassExW(&class) == 0 and Win32.GetLastError() != Win32.error_class_already_exists) {
        return error.WindowCreationFailed;
    }

    const window = Win32.CreateWindowExW(
        0,
        w("PS5PCEM_LAUNCHER"),
        w("PS5PCEM — Launcher"),
        Win32.window_style,
        Win32.centered,
        Win32.centered,
        window_width,
        window_height,
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreationFailed;
    var dark: i32 = 1;
    _ = Win32.DwmSetWindowAttribute(window, 20, &dark, @sizeOf(i32));
    _ = Win32.ShowWindow(window, Win32.show_normal);
    _ = Win32.UpdateWindow(window);

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
            Win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return Win32.DefWindowProcW(window, message, word_parameter, long_parameter);
}

fn handleClick(window: Win32.Window, x: i32, y: i32) void {
    if ((Rect{ .left = 20, .top = 126, .right = 202, .bottom = 174 }).contains(x, y)) {
        current_page = .library;
    } else if ((Rect{ .left = 20, .top = 184, .right = 202, .bottom = 232 }).contains(x, y)) {
        current_page = .input;
    } else if ((Rect{ .left = 20, .top = 242, .right = 202, .bottom = 290 }).contains(x, y)) {
        current_page = .settings;
    } else if ((Rect{ .left = 20, .top = 684, .right = 202, .bottom = 724 }).contains(x, y)) {
        openGithub(window);
    } else switch (current_page) {
        .library => handleLibraryClick(window, x, y),
        .input => handleInputClick(x, y),
        .settings => handleSettingsClick(x, y),
    }
    _ = Win32.InvalidateRect(window, null, 0);
}

fn handleLibraryClick(window: Win32.Window, x: i32, y: i32) void {
    if ((Rect{ .left = 846, .top = 235, .right = 1086, .bottom = 283 }).contains(x, y)) {
        chooseGameFolder(window);
        return;
    }
    if ((Rect{ .left = 812, .top = 646, .right = 1086, .bottom = 700 }).contains(x, y)) {
        launchGame(window);
        return;
    }
    if ((Rect{ .left = 282, .top = 415, .right = 528, .bottom = 535 }).contains(x, y)) {
        sound_enabled = !sound_enabled;
        saveSettings();
        setStatusPhrase(if (sound_enabled) .status_sound_on else .status_sound_off, false);
        return;
    }
    if ((Rect{ .left = 550, .top = 415, .right = 1086, .bottom = 535 }).contains(x, y)) {
        current_page = .input;
    }
}

fn handleInputClick(x: i32, y: i32) void {
    for (0..4) |index| {
        const left = 406 + @as(i32, @intCast(index)) * 28;
        if ((Rect{ .left = left, .top = 212, .right = left + 24, .bottom = 238 }).contains(x, y)) {
            controller_index = @intCast(index);
            saveSettings();
            setStatusPhrase(.status_controller_saved, false);
            return;
        }
    }
    const modes = [_]Rect{
        .{ .left = 282, .top = 170, .right = 532, .bottom = 246 },
        .{ .left = 548, .top = 170, .right = 798, .bottom = 246 },
        .{ .left = 814, .top = 170, .right = 1086, .bottom = 246 },
    };
    for (modes, 0..) |rectangle, index| {
        if (rectangle.contains(x, y)) {
            input_mode = @enumFromInt(index);
            saveSettings();
            setStatusPhrase(.status_input_saved, false);
            return;
        }
    }
    for (0..mapping.len) |index| {
        const column: i32 = @intCast(index / 7);
        const row: i32 = @intCast(index % 7);
        const rectangle = Rect{
            .left = 282 + column * 404,
            .top = 310 + row * 48,
            .right = 660 + column * 404,
            .bottom = 350 + row * 48,
        };
        if (rectangle.contains(x, y)) {
            capture_mapping = index;
            setStatusPhrase(.status_press_key, false);
            return;
        }
    }
}

fn handleSettingsClick(x: i32, y: i32) void {
    const languages = [_]Rect{
        .{ .left = 282, .top = 190, .right = 472, .bottom = 246 },
        .{ .left = 486, .top = 190, .right = 676, .bottom = 246 },
        .{ .left = 690, .top = 190, .right = 880, .bottom = 246 },
        .{ .left = 894, .top = 190, .right = 1086, .bottom = 246 },
    };
    for (languages, 0..) |rectangle, index| {
        if (rectangle.contains(x, y)) {
            language = @enumFromInt(index);
            status_length = 0;
            saveSettings();
            return;
        }
    }
    if ((Rect{ .left = 282, .top = 278, .right = 1086, .bottom = 360 }).contains(x, y)) {
        sound_enabled = !sound_enabled;
        saveSettings();
        setStatusPhrase(if (sound_enabled) .status_sound_on else .status_sound_off, false);
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
        .settings => drawSettings(dc),
    }
    drawFooter(dc);
}

fn drawBrand(dc: Win32.DeviceContext) void {
    roundFill(dc, .{ .left = 24, .top = 28, .right = 68, .bottom = 72 }, 14, 0x00ff9c3d);
    text(dc, w("P5"), -1, .{ .left = 34, .top = 39, .right = 64, .bottom = 64 }, 0x00181510, medium_font, Win32.dt_left);
    text(dc, w("PS5PCEM"), -1, .{ .left = 80, .top = 31, .right = 216, .bottom = 56 }, 0x00f4f0ea, title_font, Win32.dt_left);
    text(dc, w("LAUNCHER · PREVIEW"), -1, .{ .left = 80, .top = 57, .right = 216, .bottom = 76 }, 0x009b9088, small_font, Win32.dt_left);
}

fn drawNavigation(dc: Win32.DeviceContext) void {
    drawNavItem(dc, .library, 126, .nav_library, "01");
    drawNavItem(dc, .input, 184, .nav_input, "02");
    drawNavItem(dc, .settings, 242, .nav_settings, "03");
    localizedText(dc, .project, .{ .left = 28, .top = 650, .right = 190, .bottom = 670 }, 0x007c716a, small_font, Win32.dt_left);
    text(dc, w("GitHub · iStark  ↗"), -1, .{ .left = 28, .top = 690, .right = 198, .bottom = 716 }, 0x00ffac64, regular_font, Win32.dt_left);
}

fn drawNavItem(dc: Win32.DeviceContext, page: Page, top: i32, label: Phrase, comptime index: []const u8) void {
    if (current_page == page) roundFill(dc, .{ .left = 20, .top = top, .right = 202, .bottom = top + 48 }, 12, 0x003d3029);
    const color: u32 = if (current_page == page) 0x00fff8f1 else 0x00a39890;
    text(dc, w(index), -1, .{ .left = 34, .top = top + 15, .right = 58, .bottom = top + 38 }, if (current_page == page) 0x00ffac64 else 0x006d625b, small_font, Win32.dt_left);
    localizedText(dc, label, .{ .left = 66, .top = top + 13, .right = 200, .bottom = top + 39 }, color, medium_font, Win32.dt_left);
}

fn drawLibrary(dc: Win32.DeviceContext) void {
    pageHeading(dc, .library_heading, .library_subtitle);

    card(dc, .{ .left = 282, .top = 158, .right = 1086, .bottom = 332 });
    localizedText(dc, .folder_label, .{ .left = 310, .top = 183, .right = 600, .bottom = 205 }, 0x009b9088, small_font, Win32.dt_left);
    localizedText(dc, .folder_prompt, .{ .left = 310, .top = 211, .right = 800, .bottom = 238 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    roundFill(dc, .{ .left = 310, .top = 249, .right = 824, .bottom = 289 }, 9, 0x00201915);
    if (game_folder_length == 0) {
        localizedText(dc, .folder_empty, .{ .left = 326, .top = 260, .right = 808, .bottom = 283 }, 0x007e746d, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    } else {
        text(dc, &game_folder, @intCast(game_folder_length), .{ .left = 326, .top = 260, .right = 808, .bottom = 283 }, 0x00d8d0c9, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    }
    button(dc, .{ .left = 846, .top = 249, .right = 1058, .bottom = 289 }, .choose_folder, false);
    localizedText(dc, .legal_notice, .{ .left = 310, .top = 302, .right = 1048, .bottom = 322 }, 0x007e746d, small_font, Win32.dt_left);

    card(dc, .{ .left = 282, .top = 365, .right = 528, .bottom = 535 });
    localizedText(dc, .sound, .{ .left = 306, .top = 389, .right = 410, .bottom = 410 }, 0x009b9088, small_font, Win32.dt_left);
    localizedText(dc, if (sound_enabled) .enabled else .disabled, .{ .left = 306, .top = 423, .right = 435, .bottom = 450 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    drawToggle(dc, 442, 420, sound_enabled);
    localizedText(dc, .sound_timing, .{ .left = 306, .top = 470, .right = 498, .bottom = 522 }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_word_break);

    card(dc, .{ .left = 550, .top = 365, .right = 1086, .bottom = 535 });
    localizedText(dc, .controls, .{ .left = 576, .top = 389, .right = 760, .bottom = 410 }, 0x009b9088, small_font, Win32.dt_left);
    localizedText(dc, inputModeTitle(), .{ .left = 576, .top = 422, .right = 970, .bottom = 450 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, inputModeDescription(), .{ .left = 576, .top = 462, .right = 1010, .bottom = 493 }, 0x008b817a, regular_font, Win32.dt_left);
    localizedText(dc, .configure_layout, .{ .left = 576, .top = 502, .right = 850, .bottom = 525 }, 0x00ffac64, regular_font, Win32.dt_left);

    roundFill(dc, .{ .left = 282, .top = 564, .right = 1086, .bottom = 616 }, 10, 0x00251f1b);
    roundFill(dc, .{ .left = 300, .top = 581, .right = 309, .bottom = 590 }, 5, 0x0068d391);
    localizedText(dc, .core_ready, .{ .left = 323, .top = 577, .right = 760, .bottom = 602 }, 0x00bbb2aa, regular_font, Win32.dt_left);
    button(dc, .{ .left = 812, .top = 646, .right = 1086, .bottom = 700 }, .launch_game, game_folder_length == 0);
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

    localizedText(dc, .keyboard_layout, .{ .left = 282, .top = 278, .right = 650, .bottom = 300 }, 0x009b9088, small_font, Win32.dt_left);
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
    localizedText(dc, .mapping_hint, .{ .left = 282, .top = 660, .right = 1086, .bottom = 686 }, 0x008b817a, small_font, Win32.dt_left);
}

fn drawSettings(dc: Win32.DeviceContext) void {
    pageHeading(dc, .settings_heading, .settings_subtitle);
    localizedText(dc, .language, .{ .left = 282, .top = 158, .right = 600, .bottom = 180 }, 0x009b9088, small_font, Win32.dt_left);
    drawLanguageCard(dc, .english, .{ .left = 282, .top = 190, .right = 472, .bottom = 246 }, "English");
    drawLanguageCard(dc, .russian, .{ .left = 486, .top = 190, .right = 676, .bottom = 246 }, "Русский");
    drawLanguageCard(dc, .german, .{ .left = 690, .top = 190, .right = 880, .bottom = 246 }, "Deutsch");
    drawLanguageCard(dc, .french, .{ .left = 894, .top = 190, .right = 1086, .bottom = 246 }, "Français");

    card(dc, .{ .left = 282, .top = 278, .right = 1086, .bottom = 360 });
    localizedText(dc, .sound_output, .{ .left = 310, .top = 296, .right = 550, .bottom = 321 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, .sound_output_description, .{ .left = 310, .top = 328, .right = 760, .bottom = 350 }, 0x008b817a, regular_font, Win32.dt_left);
    drawToggle(dc, 988, 302, sound_enabled);

    card(dc, .{ .left = 282, .top = 382, .right = 1086, .bottom = 510 });
    localizedText(dc, .compatibility, .{ .left = 310, .top = 402, .right = 550, .bottom = 428 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, .compatibility_text, .{ .left = 310, .top = 440, .right = 1048, .bottom = 494 }, 0x00aaa098, regular_font, Win32.dt_left | Win32.dt_word_break);

    card(dc, .{ .left = 282, .top = 532, .right = 1086, .bottom = 636 });
    text(dc, w("PS5PCEM"), -1, .{ .left = 310, .top = 553, .right = 500, .bottom = 580 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, .author, .{ .left = 310, .top = 592, .right = 840, .bottom = 616 }, 0x00ffac64, regular_font, Win32.dt_left);
    text(dc, w("GPL-3.0-or-later"), -1, .{ .left = 860, .top = 592, .right = 1048, .bottom = 616 }, 0x008b817a, regular_font, Win32.dt_right);
}

fn pageHeading(dc: Win32.DeviceContext, heading: Phrase, subtitle: Phrase) void {
    localizedText(dc, heading, .{ .left = 282, .top = 42, .right = 1000, .bottom = 82 }, 0x00f4f0ea, title_font, Win32.dt_left);
    localizedText(dc, subtitle, .{ .left = 282, .top = 91, .right = 1086, .bottom = 118 }, 0x009b9088, regular_font, Win32.dt_left);
    roundFill(dc, .{ .left = 984, .top = 44, .right = 1086, .bottom = 72 }, 14, 0x00342a25);
    text(dc, w("EARLY BUILD"), -1, .{ .left = 1000, .top = 52, .right = 1072, .bottom = 67 }, 0x00ffac64, small_font, Win32.dt_center);
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
    if (Win32.CreateProcessW(
        @ptrCast(&runner),
        @ptrCast(&command),
        null,
        null,
        0,
        Win32.create_new_console,
        null,
        @ptrCast(&game_folder),
        &startup,
        &process,
    ) == 0) {
        setStatusPhrase(.status_launch_failed, true);
        return;
    }
    _ = Win32.CloseHandle(process.thread);
    _ = Win32.CloseHandle(process.process);
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
    game_folder_length = Win32.GetPrivateProfileStringW(w("launcher"), w("game_folder"), w(""), &game_folder, game_folder.len, @ptrCast(&ini_path));
    sound_enabled = Win32.GetPrivateProfileIntW(w("launcher"), w("sound"), 1, @ptrCast(&ini_path)) != 0;
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
    const DeviceContext = ?*anyopaque;
    const Menu = ?*anyopaque;
    const Object = ?*anyopaque;
    const Handle = ?*anyopaque;

    const Point = extern struct { x: i32, y: i32 };
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
    const wm_key_down: u32 = 0x0100;
    const wm_left_button_up: u32 = 0x0202;
    const transparent: i32 = 1;
    const dt_left: u32 = 0x0000;
    const dt_center: u32 = 0x0001;
    const dt_right: u32 = 0x0002;
    const dt_word_break: u32 = 0x0010;
    const dt_no_prefix: u32 = 0x0800;
    const dt_end_ellipsis: u32 = 0x8000;
    const null_pen: i32 = 8;
    const arrow_cursor: [*:0]const u16 = @ptrFromInt(32512);
    const error_class_already_exists: u32 = 1410;
    const bif_return_only_fs_dirs: u32 = 0x0001;
    const bif_new_dialog_style: u32 = 0x0040;
    const coinit_apartment_threaded: u32 = 0x0002;
    const invalid_file_attributes: u32 = 0xffff_ffff;
    const create_new_console: u32 = 0x0000_0010;
    const dpi_awareness_per_monitor_v2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) Instance;
    extern "kernel32" fn GetModuleFileNameW(module: Instance, output: [*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn CreateProcessW(application: ?[*:0]const u16, command: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: i32, flags: u32, environment: ?*anyopaque, directory: ?[*:0]const u16, startup: *StartupInfoW, process: *ProcessInformation) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
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
    extern "user32" fn LoadCursorW(Instance, [*:0]const u16) callconv(.winapi) Cursor;
    extern "user32" fn LoadIconW(Instance, ?[*:0]const u16) callconv(.winapi) Icon;
    extern "user32" fn BeginPaint(Window, *PaintStruct) callconv(.winapi) DeviceContext;
    extern "user32" fn EndPaint(Window, *const PaintStruct) callconv(.winapi) i32;
    extern "user32" fn GetClientRect(Window, *NativeRect) callconv(.winapi) i32;
    extern "user32" fn FillRect(DeviceContext, *const NativeRect, Brush) callconv(.winapi) i32;
    extern "user32" fn DrawTextW(DeviceContext, [*]const u16, i32, *NativeRect, u32) callconv(.winapi) i32;
    extern "user32" fn InvalidateRect(Window, ?*const NativeRect, i32) callconv(.winapi) i32;
    extern "user32" fn SetProcessDpiAwarenessContext(?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
    extern "user32" fn GetKeyNameTextW(long_parameter: i32, output: [*]u16, size: i32) callconv(.winapi) i32;

    extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) Brush;
    extern "gdi32" fn DeleteObject(Object) callconv(.winapi) i32;
    extern "gdi32" fn SelectObject(DeviceContext, Object) callconv(.winapi) Object;
    extern "gdi32" fn GetStockObject(i32) callconv(.winapi) Object;
    extern "gdi32" fn RoundRect(DeviceContext, i32, i32, i32, i32, i32, i32) callconv(.winapi) i32;
    extern "gdi32" fn SetBkMode(DeviceContext, i32) callconv(.winapi) i32;
    extern "gdi32" fn SetTextColor(DeviceContext, u32) callconv(.winapi) u32;
    extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) Font;

    extern "shell32" fn SHBrowseForFolderW(*BrowseInfoW) callconv(.winapi) ?*anyopaque;
    extern "shell32" fn SHGetPathFromIDListW(?*anyopaque, [*]u16) callconv(.winapi) i32;
    extern "shell32" fn ShellExecuteW(Window, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) Handle;
    extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
    extern "dwmapi" fn DwmSetWindowAttribute(Window, u32, *const anyopaque, u32) callconv(.winapi) i32;
} else struct {};
