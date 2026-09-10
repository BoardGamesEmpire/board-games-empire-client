/// Shared native (mobile + desktop) composition root.
///
/// Composes the concrete storage and network packages into the
/// `PlatformBootstrap` contract consumed by `app_shell`: encrypted MetaDB,
/// meta repositories, the real `ServerContextFactory` (storage + network
/// installers), the `ServerOrchestrator`, the device-global root
/// container (#72) with its registrations (`BuildInfo` #35, the durable
/// `FeedbackSink` #69), the `app_links`-backed deep-link source with its
/// MetaDB server lookup (#10), and the rotating-file log sink (#100).
/// `mobile_platform` and `desktop_platform` wrap this and add their
/// platform-specific concerns.
library;

export 'src/build_info/package_info_build_info_reader.dart';
export 'src/deep_links/app_links_deep_link_source.dart';
export 'src/deep_links/server_repository_known_server_lookup.dart';
export 'src/feedback/file_feedback_sink.dart';
export 'src/logging/rotating_file_log_sink.dart';
export 'src/native_platform_bootstrap.dart';
export 'src/native_root_module.dart';
