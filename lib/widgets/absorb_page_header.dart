import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../screens/settings_screen.dart';

/// Consistent page header used across all screens.
///
/// Shows the ABSORB branding + page title, left-aligned, with optional
/// trailing actions.  Designed to be placed inside scrollable content
/// (CustomScrollView slivers, ListView children, etc.) so it scrolls
/// away with the page.
class AbsorbPageHeader extends StatelessWidget {
  final String title;
  final Color? brandingColor;
  final Color? titleColor;
  final List<Widget>? actions;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  /// When true, a settings gear is shown next to the branding/cloud that opens
  /// the Settings screen. Used on the main tab screens now that Settings is no
  /// longer a bottom-nav tab.
  final bool showSettings;

  /// When true, a back chevron is shown before the branding that pops the
  /// current route. Used on pushed pages (e.g. Settings) that have no other
  /// way to dismiss.
  final bool showBack;

  const AbsorbPageHeader({
    super.key,
    required this.title,
    this.brandingColor,
    this.titleColor,
    this.actions,
    this.trailing,
    this.showSettings = false,
    this.showBack = false,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 0),
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context)!;
    final bColor = brandingColor ?? cs.onSurfaceVariant;
    final tColor = titleColor ?? cs.onSurface;

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Branding row — ABSORB + optional actions
          LayoutBuilder(
            builder: (ctx, lc) {
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Row(
                  children: [
                    if (showBack) ...[
                      InkResponse(
                        radius: 20,
                        onTap: () => Navigator.of(context).maybePop(),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.arrow_back_rounded,
                            size: 22,
                            color: tColor,
                          ),
                        ),
                      ),
                    ],
                    Text(
                      l.appTitle,
                      style: tt.labelSmall?.copyWith(
                        color: bColor,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                    if (showSettings) ...[
                      const SizedBox(width: 2),
                      InkResponse(
                        radius: 18,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.settings_outlined,
                            size: 18,
                            color: bColor,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (actions != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: (lc.maxWidth - 140).clamp(0.0, double.infinity),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 8,
                            children: actions!,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          // Page title
          Text(
            title,
            style: tt.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: tColor,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}
