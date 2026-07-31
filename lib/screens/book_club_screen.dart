import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/wishlist_service.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/offline_status_icon.dart';

/// Group book club — current pick with per-member progress, join/leave, and a
/// "next book" nomination poll. Admin (root) sets the pick, a finish-by goal,
/// and can end it. Backed by [WishlistService] (`/api/club*`).
class BookClubScreen extends StatefulWidget {
  const BookClubScreen({super.key});

  @override
  State<BookClubScreen> createState() => _BookClubScreenState();
}

class _BookClubScreenState extends State<BookClubScreen> {
  WishlistService? _service;
  ClubState? _state;
  bool _loading = true;
  Object? _error;

  bool get _admin => _state?.admin ?? false;

  @override
  void initState() {
    super.initState();
    _service = _buildService();
    _load();
  }

  WishlistService? _buildService() {
    final auth = context.read<AuthProvider>();
    final base = WishlistService.deriveBaseUrl(auth.activeServerUrl);
    final token = auth.token;
    if (base == null || token == null || token.isEmpty) return null;
    return WishlistService(
      baseUrl: base,
      token: token,
      customHeaders: auth.customHeaders,
    );
  }

  Future<void> _load() async {
    final svc = _service;
    if (svc == null) {
      setState(() {
        _loading = false;
        _error = 'not_connected';
      });
      return;
    }
    setState(() {
      _loading = _state == null;
      _error = null;
    });
    try {
      final state = await svc.getClub();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      _toast(_errorText(e));
    }
  }

  Future<void> _toggleJoin() => _run(() => _service!.toggleJoin());
  Future<void> _voteNomination(String id) =>
      _run(() => _service!.voteNomination(id));

  Future<void> _nominate() async {
    final item = await _pickLibraryItem('Nominate a book');
    if (item != null) {
      await _run(() => _service!.nominate(item.id));
    }
  }

  Future<void> _setPick() async {
    final item = await _pickLibraryItem('Set the club pick');
    if (item != null) {
      await _run(() => _service!.setClub(item.id));
    }
  }

  Future<void> _endPick() async {
    final ok = await _confirm('End this pick?',
        'The current book club pick will be cleared.');
    if (ok) await _run(() => _service!.setClub(null));
  }

  Future<void> _removeNomination(ClubNomination n) async {
    final ok = await _confirm('Remove nomination?', '"${n.title}" will be removed.');
    if (ok) await _run(() => _service!.removeNomination(n.id));
  }

  Future<void> _setGoal() async {
    final now = DateTime.now();
    final existing = _tryDate(_state?.book?.endDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: existing ?? now.add(const Duration(days: 14)),
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Finish-by goal',
    );
    if (picked == null) return;
    final iso = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    await _run(() => _service!.setClubGoal(iso));
  }

  Future<void> _clearGoal() => _run(() => _service!.setClubGoal(null));

  Future<ClubLibraryItem?> _pickLibraryItem(String title) {
    return showModalBottomSheet<ClubLibraryItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _ClubLibrarySearchSheet(service: _service!, title: title),
    );
  }

  Future<void> _openNominee(ClubNomination n) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _NomineeDetailSheet(service: _service!, nomination: n),
    );
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return ok == true;
  }

  String _errorText(Object e) {
    if (e is WishlistException) {
      switch (e.kind) {
        case WishlistErrorKind.network:
          return 'Can\'t reach the book club server';
        case WishlistErrorKind.unauthorized:
          return 'Session expired — sign in again';
        case WishlistErrorKind.forbidden:
          return 'You don\'t have permission for that';
        case WishlistErrorKind.conflict:
          return 'You\'ve already nominated a book this round';
        default:
          return e.message;
      }
    }
    return '$e';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AbsorbPageHeader(
            title: l.appShellBookClubTab,
            showSettings: true,
            trailing: OfflineStatusIcon(
              onTapWhenOnline: () =>
                  context.read<LibraryProvider>().setManualOffline(true),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_service == null) {
      return _centered('Sign in to your server to use the book club', cs,
          Icons.lock_outline);
    }
    if (_error != null && _state == null) {
      return _centered(_errorText(_error!), cs, Icons.cloud_off_rounded,
          onRetry: _load);
    }
    final state = _state!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (state.book == null)
            _noPick(cs)
          else ...[
            _currentPick(cs, state),
            const SizedBox(height: 20),
            _membersSection(cs, state),
          ],
          const SizedBox(height: 24),
          _nominationsSection(cs, state),
        ],
      ),
    );
  }

  // ── Current pick ──

  Widget _noPick(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.groups_outlined,
              size: 40, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text('No book club pick yet',
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            _admin
                ? 'Set the current pick, or let the group nominate below.'
                : 'Nominate one below, or wait for an admin to set the pick.',
            textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (_admin) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _setPick,
              icon: const Icon(Icons.auto_stories_rounded, size: 18),
              label: const Text('Set the pick'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _currentPick(ColorScheme cs, ClubState state) {
    final tt = Theme.of(context).textTheme;
    final b = state.book!;
    final meta = [
      if (b.series?.isNotEmpty == true) b.series!,
      if (b.narrator?.isNotEmpty == true) 'Narrated by ${b.narrator}',
      if (_durationLabel(b.durationSec) != null) _durationLabel(b.durationSec)!,
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CURRENT PICK',
              style: tt.labelSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1)),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 84,
                  height: 84,
                  child: CachedNetworkImage(
                    imageUrl: _service!.clubCoverUrl(b.itemId),
                    httpHeaders: _service!.imageHeaders,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: cs.surfaceContainerHighest),
                    errorWidget: (_, __, ___) => Container(
                      color: cs.surfaceContainerHighest,
                      child: Icon(Icons.menu_book_rounded,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(b.title,
                        style:
                            tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(b.author,
                        style: tt.bodyMedium
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(meta.join(' · '),
                          style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant
                                  .withValues(alpha: 0.8))),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_goalLabel(b.endDate) != null) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Text('🎯 ', style: TextStyle(fontSize: 13)),
              Text(_goalLabel(b.endDate)!,
                  style: tt.bodySmall?.copyWith(color: cs.primary)),
            ]),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: state.joined
                  ? OutlinedButton.icon(
                      onPressed: _toggleJoin,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Joined'),
                    )
                  : FilledButton.icon(
                      onPressed: _toggleJoin,
                      icon: const Icon(Icons.group_add_rounded, size: 18),
                      label: const Text('Join'),
                    ),
            ),
          ]),
          if (_admin) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _setPick,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('Change'),
                ),
                TextButton.icon(
                  onPressed: _setGoal,
                  icon: const Icon(Icons.flag_outlined, size: 18),
                  label: Text(b.endDate == null ? 'Set goal' : 'Edit goal'),
                ),
                if (b.endDate != null)
                  TextButton.icon(
                    onPressed: _clearGoal,
                    icon: const Icon(Icons.flag_rounded, size: 18),
                    label: const Text('Clear goal'),
                  ),
                TextButton.icon(
                  onPressed: _endPick,
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('End pick'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Members ──

  Widget _membersSection(ColorScheme cs, ClubState state) {
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Progress',
            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        if (state.members.isEmpty)
          Text('No one\'s joined yet.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
        else
          ...state.members.map((m) => _memberTile(cs, tt, m)),
      ],
    );
  }

  Widget _memberTile(ColorScheme cs, TextTheme tt, ClubMember m) {
    final pct = (m.progress.clamp(0, 1) * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(m.name,
                    style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (m.isFinished)
                Row(children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: cs.primary),
                  const SizedBox(width: 4),
                  Text('Finished',
                      style: tt.labelSmall?.copyWith(color: cs.primary)),
                ])
              else
                Text('$pct%',
                    style: tt.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: m.progress.clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                  m.isFinished ? cs.primary : cs.primary.withValues(alpha: 0.8)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Nominations ──

  Widget _nominationsSection(ColorScheme cs, ClubState state) {
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Next book',
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(
              onPressed: _nominate,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Nominate'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (state.nominations.isEmpty)
          Text('No nominations yet. Nominate a book from your library.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
        else
          ...state.nominations.map((n) => _nominationTile(cs, tt, n)),
      ],
    );
  }

  Widget _nominationTile(ColorScheme cs, TextTheme tt, ClubNomination n) {
    final canRemove = n.mine || _admin;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _openNominee(n),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [n.author, 'by ${n.submittedBy}']
                        .where((s) => s.trim().isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Text('Read synopsis',
                      style: tt.labelSmall?.copyWith(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (canRemove)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded,
                  size: 18, color: cs.onSurfaceVariant),
              onPressed: () => _removeNomination(n),
            ),
          // Vote pill (submitter auto-supports; can't vote own).
          _votePill(cs, tt, n),
        ],
      ),
    );
  }

  Widget _votePill(ColorScheme cs, TextTheme tt, ClubNomination n) {
    final active = n.voted;
    final disabled = n.mine;
    return InkWell(
      onTap: disabled ? null : () => _voteNomination(n.id),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? cs.primary.withValues(alpha: 0.18)
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: active
              ? Border.all(color: cs.primary.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(active ? Icons.arrow_upward_rounded : Icons.arrow_upward_rounded,
              size: 14,
              color: active ? cs.primary : cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text('${n.score}',
              style: tt.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: active ? cs.primary : cs.onSurface)),
        ]),
      ),
    );
  }

  Widget _centered(String text, ColorScheme cs, IconData icon,
      {VoidCallback? onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }

  // ── formatting helpers ──

  static DateTime? _tryDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  String? _durationLabel(double? sec) {
    if (sec == null || sec <= 0) return null;
    final mins = (sec / 60).round();
    final h = mins ~/ 60, m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    return h > 0 ? '${h}h' : '${m}m';
  }

  String? _goalLabel(String? endDate) {
    final d = _tryDate(endDate);
    if (d == null) return null;
    final today = DateTime.now();
    final days =
        DateTime(d.year, d.month, d.day).difference(DateTime(today.year, today.month, today.day)).inDays;
    final by = 'finish by ${d.month}/${d.day}';
    if (days > 1) return 'Goal: $by — $days days left';
    if (days == 1) return 'Goal: $by — 1 day left';
    if (days == 0) return 'Goal: $by — due today';
    return 'Goal: $by — past due';
  }
}

// ─── Library search sheet (set pick / nominate) ─────────────────────

class _ClubLibrarySearchSheet extends StatefulWidget {
  const _ClubLibrarySearchSheet({required this.service, required this.title});
  final WishlistService service;
  final String title;

  @override
  State<_ClubLibrarySearchSheet> createState() =>
      _ClubLibrarySearchSheetState();
}

class _ClubLibrarySearchSheetState extends State<_ClubLibrarySearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  Object? _error;
  List<ClubLibraryItem> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.service.clubSearch(query);
      if (!mounted) return;
      setState(() {
        _results = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.title,
                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: _search,
                decoration: InputDecoration(
                  hintText: 'Search your library…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : _error != null
                      ? Center(
                          child: Text('Search failed',
                              style:
                                  TextStyle(color: cs.onSurfaceVariant)))
                      : _results.isEmpty
                          ? Center(
                              child: Text('Search your library',
                                  style: TextStyle(
                                      color: cs.onSurfaceVariant)))
                          : ListView.separated(
                              controller: scroll,
                              padding:
                                  const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: _results.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 14),
                              itemBuilder: (_, i) {
                                final it = _results[i];
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(it.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    [
                                      it.author,
                                      if (it.series?.isNotEmpty == true)
                                        it.series!
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: tt.bodySmall?.copyWith(
                                        color: cs.onSurfaceVariant),
                                  ),
                                  trailing: const Icon(
                                      Icons.chevron_right_rounded),
                                  onTap: () => Navigator.pop(context, it),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Nominee detail sheet ───────────────────────────────────────────

class _NomineeDetailSheet extends StatefulWidget {
  const _NomineeDetailSheet({required this.service, required this.nomination});
  final WishlistService service;
  final ClubNomination nomination;

  @override
  State<_NomineeDetailSheet> createState() => _NomineeDetailSheetState();
}

class _NomineeDetailSheetState extends State<_NomineeDetailSheet> {
  String? _summary;
  String? _asin;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final d = await widget.service.clubItemDetail(widget.nomination.itemId);
      if (!mounted) return;
      setState(() {
        _summary = d.summary;
        _asin = d.asin;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openAudible() async {
    final asin = _asin;
    if (asin == null || asin.isEmpty) return;
    await launchUrl(Uri.parse('https://www.audible.com/pd/$asin'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final n = widget.nomination;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              children: [
                Text(n.title,
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(n.author,
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text('Nominated by ${n.submittedBy}',
                    style: tt.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.8))),
                if (_asin != null && _asin!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openAudible,
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Open in Audible'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text('Synopsis',
                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if ((_summary ?? '').isEmpty)
                  Text('No description available.',
                      style:
                          tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
                else
                  Text(_summary!,
                      style: tt.bodyMedium?.copyWith(
                          height: 1.5,
                          color: cs.onSurface.withValues(alpha: 0.9))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
