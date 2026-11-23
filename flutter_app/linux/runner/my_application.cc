#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "toggle_rule.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // "maprisma/window": tells the app its window is shown again (popup mode
  // places it then).
  FlMethodChannel* window_channel;
  // When the window last hid by itself (popup mode: a click elsewhere, which
  // the bar click also is), so the toggle that click sends leaves it hidden.
  gint64 hidden_at;
  // The toggle is hiding the window (that hide is not "by itself").
  gboolean toggling;
  // The app's window, the folder dialog's parent.
  GtkWindow* main_window;
  // The open folder dialog and the "chooseFolder" call it answers.
  GtkWidget* folder_dialog;
  FlMethodCall* folder_call;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void notify_shown(MyApplication* self) {
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, "shown", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

// "#rrggbb" or null.
static const gchar* hex_arg(FlValue* map, const gchar* key) {
  FlValue* v = fl_value_lookup_string(map, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
  const gchar* s = fl_value_get_string(v);
  if (strlen(s) != 7 || s[0] != '#') return nullptr;
  for (int i = 1; i < 7; i++) {
    if (!g_ascii_isxdigit(s[i])) return nullptr;
  }
  return s;
}

// GTK draws the header bar in the GTK theme's colours (Adwaita's blue-grey
// on Hyprland), so it takes the app's background and text through a CSS
// provider of its own, as Maprisma Settings and Theme do.
static void set_header_colors(const gchar* bg, const gchar* fg,
                              const gchar* border) {
  static GtkCssProvider* provider = nullptr;
  GdkScreen* screen = gdk_screen_get_default();
  if (screen == nullptr) return;
  if (provider == nullptr) {
    provider = gtk_css_provider_new();
    gtk_style_context_add_provider_for_screen(
        screen, GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  }
  g_autofree gchar* css = g_strdup_printf(
      "headerbar, headerbar:backdrop, .titlebar, .titlebar:backdrop {"
      " background: %s; background-image: none; color: %s;"
      " border-color: %s; box-shadow: none; }"
      " headerbar .title, headerbar button, headerbar button image {"
      " color: %s; }"
      " headerbar:backdrop .title, headerbar:backdrop button {"
      " color: alpha(%s, 0.7); }",
      bg, fg, border, fg, fg);
  gtk_css_provider_load_from_data(provider, css, -1, nullptr);
}

// "chooseFolder" {title, accept, initial, shortcuts}: GTK's folder dialog with
// the mounted disks and pinned folders the Dart side found in its sidebar
// (file_selector has no shortcut folders). It is GTK's own dialog, not
// GtkFileChooserNative, which hands the request to the desktop portal when
// one is used (GTK_USE_PORTAL=1) and drops the shortcuts. It does not block:
// the call is answered (the chosen path or null) when the dialog closes; a
// second call while it is open brings it to the front and answers null.
static void folder_dialog_finish(MyApplication* self, FlValue* chosen) {
  FlMethodCall* call = self->folder_call;
  GtkWidget* dialog = self->folder_dialog;
  self->folder_call = nullptr;
  self->folder_dialog = nullptr;
  if (call != nullptr) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(chosen));
    fl_method_call_respond(call, response, nullptr);
    g_object_unref(call);
  }
  if (dialog != nullptr) gtk_widget_destroy(dialog);
}

static void folder_dialog_response_cb(GtkDialog* dialog, gint response_id,
                                      gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlValue) chosen = fl_value_new_null();
  if (response_id == GTK_RESPONSE_ACCEPT) {
    g_autofree gchar* path =
        gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
    if (path != nullptr) {
      fl_value_unref(chosen);
      chosen = fl_value_new_string(path);
    }
  }
  folder_dialog_finish(self, chosen);
}

static void choose_folder(MyApplication* self, FlMethodCall* call) {
  if (self->folder_dialog != nullptr) {
    gtk_window_present(GTK_WINDOW(self->folder_dialog));
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  // GTK's own translations for the defaults, in the desktop's language.
  const gchar* title = g_dgettext("gtk30", "Select a folder");
  const gchar* accept = g_dgettext("gtk30", "_Select");
  const gchar* initial = nullptr;
  FlValue* shortcuts = nullptr;
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* value = fl_value_lookup_string(args, "title");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      title = fl_value_get_string(value);
    }
    value = fl_value_lookup_string(args, "accept");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      accept = fl_value_get_string(value);
    }
    value = fl_value_lookup_string(args, "initial");
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      initial = fl_value_get_string(value);
    }
    shortcuts = fl_value_lookup_string(args, "shortcuts");
  }
  GtkWidget* dialog = gtk_file_chooser_dialog_new(
      title, self->main_window, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
      g_dgettext("gtk30", "_Cancel"), GTK_RESPONSE_CANCEL, accept,
      GTK_RESPONSE_ACCEPT, nullptr);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  gtk_window_set_modal(GTK_WINDOW(dialog), TRUE);
  GtkFileChooser* chooser = GTK_FILE_CHOOSER(dialog);
  if (shortcuts != nullptr && fl_value_get_type(shortcuts) == FL_VALUE_TYPE_LIST) {
    for (size_t i = 0; i < fl_value_get_length(shortcuts); i++) {
      FlValue* item = fl_value_get_list_value(shortcuts, i);
      if (fl_value_get_type(item) != FL_VALUE_TYPE_STRING) continue;
      // A folder GTK already lists (or that is gone) is refused; that is fine.
      gtk_file_chooser_add_shortcut_folder(chooser, fl_value_get_string(item),
                                           nullptr);
    }
  }
  if (initial != nullptr && g_file_test(initial, G_FILE_TEST_IS_DIR)) {
    gtk_file_chooser_set_current_folder(chooser, initial);
  }
  self->folder_dialog = dialog;
  self->folder_call = FL_METHOD_CALL(g_object_ref(call));
  g_signal_connect(dialog, "response", G_CALLBACK(folder_dialog_response_cb),
                   self);
  gtk_widget_show(dialog);
}

// "titlebar": GTK draws the title bar, so it takes the app's light or dark
// (a bool) or {dark, background, foreground, border} with its colours.
static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "titlebar") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      g_object_set(gtk_settings_get_default(),
                   "gtk-application-prefer-dark-theme", fl_value_get_bool(args),
                   nullptr);
    } else if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* dark = fl_value_lookup_string(args, "dark");
      if (dark != nullptr && fl_value_get_type(dark) == FL_VALUE_TYPE_BOOL) {
        g_object_set(gtk_settings_get_default(),
                     "gtk-application-prefer-dark-theme",
                     fl_value_get_bool(dark), nullptr);
      }
      const gchar* bg = hex_arg(args, "background");
      const gchar* fg = hex_arg(args, "foreground");
      const gchar* border = hex_arg(args, "border");
      if (bg != nullptr && fg != nullptr) {
        set_header_colors(bg, fg, border != nullptr ? border : bg);
      }
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(fl_method_call_get_name(call), "chooseFolder") == 0) {
    // Answered when the dialog closes.
    choose_folder(MY_APPLICATION(user_data), call);
    return;
  } else if (g_strcmp0(fl_method_call_get_name(call), "tiled") == 0) {
    // Whether the compositor tiles the window (COSMIC's auto-tiling, KWin's quick tiles):
    // its size then isn't the user's, so it isn't remembered. window_manager only knows
    // maximised and full screen.
    GtkWindow* window =
        gtk_application_get_active_window(GTK_APPLICATION(user_data));
    GdkWindow* gdk_window =
        window != nullptr ? gtk_widget_get_window(GTK_WIDGET(window)) : nullptr;
    gboolean tiled =
        gdk_window != nullptr &&
        (gdk_window_get_state(gdk_window) & GDK_WINDOW_STATE_TILED) != 0;
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(tiled)));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  notify_shown(self);
}

// The window closes: an open folder dialog answers null and closes with it.
static void main_window_destroyed_cb(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->main_window = nullptr;
  if (self->folder_dialog != nullptr || self->folder_call != nullptr) {
    folder_dialog_finish(self, nullptr);
  }
}

static void window_hidden_cb(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->hidden_at = self->toggling ? 0 : g_get_monotonic_time();
}

// The "toggle" action (maprisma --toggle, the bar icon, a shortcut): a shown
// window hides, focused or not (on COSMIC a panel click takes the focus
// first, and a window behind others is shown too: the family's rule); a
// hidden one is shown and focused. A popup that just hid itself on the bar
// click stays hidden instead of coming straight back.
static void toggle_activated(GSimpleAction* action, GVariant* parameter,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window =
      gtk_application_get_active_window(GTK_APPLICATION(self));
  if (window == nullptr) {
    g_application_activate(G_APPLICATION(self));
    return;
  }
  const MaprismaToggle step = maprisma_toggle_step(
      gtk_widget_get_visible(GTK_WIDGET(window)), self->hidden_at,
      g_get_monotonic_time());
  self->hidden_at = 0;
  if (step == MAPRISMA_TOGGLE_HIDE) {
    self->toggling = TRUE;
    gtk_widget_hide(GTK_WIDGET(window));
    self->toggling = FALSE;
    return;
  }
  if (step == MAPRISMA_TOGGLE_STAY) return;
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
  notify_shown(self);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* existing = gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing != nullptr) {
    gtk_widget_show(GTK_WIDGET(existing));
    gtk_window_present(existing);
    notify_shown(self);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  // App windows (window_style.dart, chosen in Maprisma Settings): an RGBA window,
  // so a see-through background shows the desktop (Flutter paints the background itself).
  GdkVisual* rgba_visual = gdk_screen_get_rgba_visual(gtk_widget_get_screen(GTK_WIDGET(window)));
  if (rgba_visual != nullptr) {
    gtk_widget_set_visual(GTK_WIDGET(window), rgba_visual);
    gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  }

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Maprisma");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Maprisma");
  }

  // 1280×720, but never more than 90 % × 80 % of the screen (small screens, task 073). COSMIC
  // decides a floating window's first size itself (about two thirds of the screen) and ignores
  // this; the size the user gave the window last time (window.json) is applied by the Dart side.
  gint width = 1280, height = 720;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = display != nullptr ? gdk_display_get_primary_monitor(display) : nullptr;
  if (monitor == nullptr && display != nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    if (area.width > 0 && area.height > 0) {
      width = MIN(width, area.width * 9 / 10);
      height = MIN(height, area.height * 8 / 10);
    }
  }
  gtk_window_set_default_size(window, width, height);
  g_signal_connect(window, "hide", G_CALLBACK(window_hidden_cb), self);
  self->main_window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(main_window_destroyed_cb),
                   self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  if (rgba_visual != nullptr) background_color.alpha = 0;
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "maprisma/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_call_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name; --toggle is the
  // runner's own (the bar icon), not the app's.
  gboolean toggle = FALSE;
  GPtrArray* kept = g_ptr_array_new();
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "--toggle") == 0) {
      toggle = TRUE;
    } else {
      g_ptr_array_add(kept, g_strdup(*arg));
    }
  }
  g_ptr_array_add(kept, nullptr);
  self->dart_entrypoint_arguments =
      reinterpret_cast<char**>(g_ptr_array_free(kept, FALSE));

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // Another instance runs: it shows or hides its window. Else this one
  // starts as usual (shown).
  if (toggle && g_application_get_is_remote(application)) {
    g_action_group_activate_action(G_ACTION_GROUP(application), "toggle",
                                   nullptr);
    // Sent before this process ends.
    GDBusConnection* bus = g_application_get_dbus_connection(application);
    if (bus != nullptr) g_dbus_connection_flush_sync(bus, nullptr, nullptr);
    *exit_status = 0;
    return TRUE;
  }
  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  g_autoptr(GSimpleAction) toggle = g_simple_action_new("toggle", nullptr);
  g_signal_connect(toggle, "activate", G_CALLBACK(toggle_activated),
                   application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(toggle));
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  // An open folder dialog answers null and closes before the channel goes.
  if (self->folder_dialog != nullptr || self->folder_call != nullptr) {
    folder_dialog_finish(self, nullptr);
  }
  g_clear_object(&self->window_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_FLAGS_NONE, nullptr));
}
