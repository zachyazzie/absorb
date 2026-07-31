import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/absorb_page_header.dart';

/// Group book club — current pick, per-member progress, join/leave, and
/// nominations/voting for the next book. Backed by the wishlist server.
class BookClubScreen extends StatelessWidget {
  const BookClubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context)!;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AbsorbPageHeader(title: l.appShellBookClubTab, showSettings: true),
          Expanded(
            child: Center(
              child: Text(
                'Book Club',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
