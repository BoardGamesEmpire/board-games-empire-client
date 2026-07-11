#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Deep links (#10): with G_APPLICATION_HANDLES_OPEN a second launch (e.g.
  // from xdg-open bge://...) re-activates this single instance instead of
  // starting a new one. Present the existing window and return rather than
  // building a second one.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

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
    gtk_header_bar_set_title(header_bar, "desktop");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "desktop");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument (the binary name), AND any bge:// deep-link
  // URL (#10). GApplication (HANDLES_OPEN) already routes the URL to
  // app_links via the open signal; forwarding it again through Dart's
  // main(List<String> args) would double-handle it and leak raw invite/RSVP
  // tokens into the process arguments. Case-insensitive: the scheme is
  // case-insensitive and some launchers preserve casing.
  gchar** argv = *arguments;
  GPtrArray* filtered = g_ptr_array_new();
  for (int i = 1; argv[i] != nullptr; i++) {
    if (g_ascii_strncasecmp(argv[i], "bge://", 6) == 0) {
      continue;
    }
    g_ptr_array_add(filtered, g_strdup(argv[i]));
  }
  g_ptr_array_add(filtered, nullptr);
  // Free the container but keep the (null-terminated) buffer; g_strfreev in
  // dispose owns it thereafter.
  self->dart_entrypoint_arguments =
      static_cast<gchar**>(g_ptr_array_free(filtered, FALSE));

  g_autoptr(GError) error = nullptr;
  // Registration must precede the manual activate below
  // (g_application_activate asserts the app is registered). A genuine
  // registration failure is the one path we fully handle locally: set the
  // status and return TRUE so no further processing runs.
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // Guarantee a window even on a cold start opened via a bge:// URL (#10):
  // with HANDLES_OPEN that path emits `open` (where app_links captures the
  // link), not `activate`, and we don't implement an open-based window
  // builder. The gtk_application_get_windows guard in
  // my_application_activate keeps this idempotent with the activation
  // GApplication performs on the FALSE path below (no duplicate window).
  g_application_activate(application);

  // Return FALSE so GApplication drives its default handling: forward the
  // command line / bge:// URL to the primary instance (single-instance) and
  // emit `open` so app_links receives the link. Deliberately do NOT set
  // *exit_status here — on the FALSE path GApplication computes it after the
  // default processing, so any value set here is dead.
  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
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

  // Deep links (#10): HANDLES_COMMAND_LINE | HANDLES_OPEN (replacing
  // NON_UNIQUE) makes this a single-instance app that receives bge:// URLs
  // via GApplication::open and forwards subsequent launches to the running
  // instance (see my_application_activate / _local_command_line).
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
