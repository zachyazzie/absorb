import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../services/wishlist_service.dart';
import '../widgets/absorb_page_header.dart';

/// Group audiobook wishlist — search Audible, add titles, up/down vote on what
/// to buy next, and claim ("I'm grabbing this"). Backed by [WishlistService].
class WishlistScreen extends StatefulWidget {
  const WishlistScreen({super.key});

  @override
  State<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  WishlistService? _service;
  WishlistState? _state;
  bool _loading = true;
  Object? _error;

  String? get _me => _state?.me?.name;
  bool get _admin => _state?.me?.admin ?? false;

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
      final state = await svc.getWishlist();
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

  void _replaceBook(WishlistBook updated) {
    final list = _state?.wanted;
    if (list == null) return;
    final i = list.indexWhere((b) => b.id == updated.id);
    if (i < 0) return;
    setState(() => list[i] = updated);
  }

  Future<void> _vote(WishlistBook book, int dir) async {
    try {
      final updated = await _service!.vote(book.id, dir);
      _replaceBook(updated);
    } catch (e) {
      _toast(_errorText(e));
    }
  }

  Future<void> _claim(WishlistBook book) async {
    try {
      final updated = await _service!.claim(book.id);
      _replaceBook(updated);
    } on WishlistException catch (e) {
      _toast(e.kind == WishlistErrorKind.conflict
          ? 'Someone else already called dibs'
          : _errorText(e));
    } catch (e) {
      _toast(_errorText(e));
    }
  }

  Future<void> _remove(WishlistBook book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from wishlist?'),
        content: Text('"${book.title}" will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service!.removeItem(book.id);
      setState(() => _state?.wanted.removeWhere((b) => b.id == book.id));
    } catch (e) {
      _toast(_errorText(e));
    }
  }

  Future<void> _openAudible(String asin) async {
    if (asin.isEmpty) return;
    final uri = Uri.parse('https://www.audible.com/pd/$asin');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _toast('Couldn\'t open Audible');
  }

  Future<void> _openSynopsis(WishlistBook book) async {
    final svc = _service;
    if (svc == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _SynopsisSheet(
        service: svc,
        book: book,
        onOpenAudible: () => _openAudible(book.asin),
      ),
    );
  }

  Future<void> _openSearch() async {
    final svc = _service;
    if (svc == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _WishlistSearchSheet(service: svc),
    );
    _load(); // refresh after possible adds
  }

  String _errorText(Object e) {
    if (e is WishlistException) {
      switch (e.kind) {
        case WishlistErrorKind.network:
          return 'Can\'t reach the wishlist server';
        case WishlistErrorKind.unauthorized:
          return 'Session expired — sign in again';
        case WishlistErrorKind.forbidden:
          return 'Only the person who added it (or an admin) can do that';
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
            title: l.appShellWishlistTab,
            showSettings: true,
            actions: [
              if (_service != null)
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  tooltip: 'Search & add',
                  onPressed: _openSearch,
                ),
            ],
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
      return _centered(
          'Sign in to your server to use the wishlist', cs, Icons.lock_outline);
    }
    if (_error != null && _state == null) {
      return _centered(_errorText(_error!), cs, Icons.cloud_off_rounded,
          onRetry: _load);
    }
    final wanted = [...?_state?.wanted]..sort((a, b) => b.score.compareTo(a.score));
    if (wanted.isEmpty) {
      return _centered('Nothing on the wishlist yet.\nTap + to search and add a book.',
          cs, Icons.playlist_add_rounded);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: wanted.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final book = wanted[i];
          final owner = _me != null &&
              book.addedBy.toLowerCase() == _me!.toLowerCase();
          return _WishlistTile(
            book: book,
            myVote: book.myVote(_me),
            meName: _me,
            canRemove: owner || _admin,
            canUnclaim: _admin ||
                (_me != null &&
                    (book.claimedBy ?? '').toLowerCase() == _me!.toLowerCase()),
            onVote: (dir) => _vote(book, dir),
            onClaim: () => _claim(book),
            onRemove: () => _remove(book),
            onOpenAudible: () => _openAudible(book.asin),
            onReadSynopsis: () => _openSynopsis(book),
          );
        },
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
}

// ─── Wishlist row ───────────────────────────────────────────────────

class _WishlistTile extends StatelessWidget {
  const _WishlistTile({
    required this.book,
    required this.myVote,
    required this.meName,
    required this.canRemove,
    required this.canUnclaim,
    required this.onVote,
    required this.onClaim,
    required this.onRemove,
    required this.onOpenAudible,
    required this.onReadSynopsis,
  });

  final WishlistBook book;
  final int myVote;
  final String? meName;
  final bool canRemove;
  final bool canUnclaim;
  final ValueChanged<int> onVote;
  final VoidCallback onClaim;
  final VoidCallback onRemove;
  final VoidCallback onOpenAudible;
  final VoidCallback onReadSynopsis;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final claimed = book.isClaimed;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
        border: claimed
            ? Border.all(color: cs.primary.withValues(alpha: 0.5), width: 1)
            : null,
      ),
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cover(cs),
          const SizedBox(width: 12),
          Expanded(child: _details(context, cs, tt, claimed)),
          const SizedBox(width: 8),
          _voteColumn(cs),
        ],
      ),
    );
  }

  Widget _cover(ColorScheme cs) {
    return GestureDetector(
      onTap: onReadSynopsis,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: book.coverUrl != null && book.coverUrl!.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: book.coverUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      Container(color: cs.surfaceContainerHighest),
                  errorWidget: (_, __, ___) => Container(
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.menu_book_rounded,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                  ),
                )
              : Container(
                  color: cs.surfaceContainerHighest,
                  child: Icon(Icons.menu_book_rounded,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                ),
        ),
      ),
    );
  }

  Widget _details(
      BuildContext context, ColorScheme cs, TextTheme tt, bool claimed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onReadSynopsis,
          child: Text(book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 2),
        Text(
          [book.author, if (book.narrator?.isNotEmpty == true) book.narrator!]
              .join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: onReadSynopsis,
          child: Text(
            'Read synopsis',
            style: tt.labelSmall
                ?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            // 🛒 Grab → open on Audible (buy).
            _pill(cs, tt, Icons.shopping_cart_outlined, 'Grab', onOpenAudible),
            const SizedBox(width: 8),
            if (claimed)
              // ✋ someone has dibs; claimant/admin can tap to release.
              Expanded(
                child: GestureDetector(
                  onTap: canUnclaim ? onClaim : null,
                  child: Row(
                    children: [
                      const Text('✋ ', style: TextStyle(fontSize: 12)),
                      Flexible(
                        child: Text(
                          '${book.claimedBy} called dibs',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.labelSmall?.copyWith(color: cs.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              // ✋ Dibs → claim ("I'm getting this one").
              _pill(cs, tt, Icons.back_hand_outlined, 'Dibs', onClaim),
              const Spacer(),
            ],
            if (canRemove)
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: cs.onSurfaceVariant),
                onPressed: onRemove,
              ),
          ],
        ),
      ],
    );
  }

  Widget _pill(ColorScheme cs, TextTheme tt, IconData icon, String label,
      VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 4),
          Text(label, style: tt.labelSmall?.copyWith(color: cs.primary)),
        ]),
      ),
    );
  }

  Widget _voteColumn(ColorScheme cs) {
    Color up = myVote == 1 ? cs.primary : cs.onSurfaceVariant;
    Color down = myVote == -1 ? cs.error : cs.onSurfaceVariant;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _voteBtn(Icons.keyboard_arrow_up_rounded, up, () => onVote(1)),
        Text('${book.score}',
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
                fontSize: 15)),
        _voteBtn(Icons.keyboard_arrow_down_rounded, down, () => onVote(-1)),
      ],
    );
  }

  Widget _voteBtn(IconData icon, Color color, VoidCallback onTap) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Icon(icon, color: color, size: 26),
      ),
    );
  }
}

// ─── Synopsis sheet ─────────────────────────────────────────────────

class _SynopsisSheet extends StatefulWidget {
  const _SynopsisSheet({
    required this.service,
    required this.book,
    required this.onOpenAudible,
  });
  final WishlistService service;
  final WishlistBook book;
  final VoidCallback onOpenAudible;

  @override
  State<_SynopsisSheet> createState() => _SynopsisSheetState();
}

class _SynopsisSheetState extends State<_SynopsisSheet> {
  late String? _summary = widget.book.summary;
  bool _loadingSummary = true;
  int? _lengthMin;

  @override
  void initState() {
    super.initState();
    _lengthMin = widget.book.lengthMin;
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final d = await widget.service.getBook(widget.book.asin);
      if (!mounted) return;
      setState(() {
        if ((d.summary ?? '').isNotEmpty) _summary = d.summary;
        _lengthMin ??= d.lengthMin;
        _loadingSummary = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingSummary = false); // keep stored summary fallback
    }
  }

  String? _lengthLabel() {
    final m = _lengthMin;
    if (m == null || m <= 0) return null;
    final h = m ~/ 60, mm = m % 60;
    if (h > 0 && mm > 0) return '${h}h ${mm}m';
    return h > 0 ? '${h}h' : '${mm}m';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final b = widget.book;
    final seriesLabel = (b.series?.isNotEmpty ?? false)
        ? (b.seriesPosition?.isNotEmpty == true
            ? '${b.series} #${b.seriesPosition}'
            : b.series!)
        : null;
    final meta = [
      if (b.narrator?.isNotEmpty == true) 'Narrated by ${b.narrator}',
      if (seriesLabel != null) seriesLabel,
      if (_lengthLabel() != null) _lengthLabel()!,
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: (b.coverUrl?.isNotEmpty ?? false)
                            ? CachedNetworkImage(
                                imageUrl: b.coverUrl!, fit: BoxFit.cover)
                            : Container(
                                color: cs.surfaceContainerHighest,
                                child: Icon(Icons.menu_book_rounded,
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.5))),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.title,
                              style: tt.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700)),
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
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: widget.onOpenAudible,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open in Audible'),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Synopsis',
                    style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if ((_summary ?? '').isEmpty && _loadingSummary)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if ((_summary ?? '').isEmpty)
                  Text('No description available.',
                      style: tt.bodyMedium
                          ?.copyWith(color: cs.onSurfaceVariant))
                else ...[
                  Text(_summary!,
                      style: tt.bodyMedium?.copyWith(
                          height: 1.5,
                          color: cs.onSurface.withValues(alpha: 0.9))),
                  if (_loadingSummary)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text('Loading full synopsis…',
                          style: tt.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Search & add sheet ─────────────────────────────────────────────

class _WishlistSearchSheet extends StatefulWidget {
  const _WishlistSearchSheet({required this.service});
  final WishlistService service;

  @override
  State<_WishlistSearchSheet> createState() => _WishlistSearchSheetState();
}

class _WishlistSearchSheetState extends State<_WishlistSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  Object? _error;
  List<WishlistSearchResult> _results = const [];
  final Set<String> _added = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(q));
  }

  Future<void> _run(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.service.search(query);
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

  Future<void> _add(WishlistSearchResult r) async {
    setState(() => _added.add(r.asin));
    try {
      await widget.service.add(r.asin);
    } on WishlistException catch (e) {
      if (e.kind != WishlistErrorKind.conflict) {
        setState(() => _added.remove(r.asin));
      }
      _toast(e.kind == WishlistErrorKind.conflict
          ? 'Already on the wishlist'
          : e.message);
    } catch (e) {
      setState(() => _added.remove(r.asin));
      _toast('$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
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
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: _run,
                decoration: InputDecoration(
                  hintText: 'Search Audible…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _controller.clear();
                            _run('');
                          },
                        ),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(child: _results0(scroll, cs, tt)),
          ],
        ),
      ),
    );
  }

  Widget _results0(ScrollController scroll, ColorScheme cs, TextTheme tt) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Text('Search failed: ${_error is WishlistException ? (_error as WishlistException).message : _error}',
            style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('Search Audible to add a book',
            style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 16),
      itemBuilder: (_, i) {
        final r = _results[i];
        final added = _added.contains(r.asin) || r.wishlisted;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: r.coverUrl != null && r.coverUrl!.isNotEmpty
                    ? CachedNetworkImage(imageUrl: r.coverUrl!, fit: BoxFit.cover)
                    : Container(color: cs.surfaceContainerHighest),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(r.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (r.owned)
              Chip(
                label: const Text('Owned'),
                visualDensity: VisualDensity.compact,
              )
            else if (added)
              Icon(Icons.check_circle_rounded, color: cs.primary)
            else
              FilledButton.tonal(
                onPressed: () => _add(r),
                child: const Text('Add'),
              ),
          ],
        );
      },
    );
  }
}
