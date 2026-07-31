import 'package:flutter/widgets.dart';

import '../services/wishlist_service.dart';
import 'auth_provider.dart';

/// Shared state for the Wishlist and Book Club tabs.
///
/// Owns a single [WishlistService] (rebuilt when the active account/token
/// changes) and caches the last-loaded wishlist + club state so switching
/// between the two tabs is instant, with pull-to-refresh to update. Mirrors
/// the `ChangeNotifierProxyProvider<AuthProvider, …>` pattern used by
/// LibraryProvider.
class WishlistProvider extends ChangeNotifier {
  WishlistService? _service;
  String? _key;

  WishlistService? get service => _service;
  bool get connected => _service != null;

  // ── Wishlist ──
  WishlistState? wishlist;
  bool wishlistLoading = false;
  Object? wishlistError;

  // ── Book club ──
  ClubState? club;
  bool clubLoading = false;
  Object? clubError;

  /// Whoever we last identified as, and whether they're an admin — shared by
  /// both tabs so neither has to look it up separately.
  WishlistMe? get me => wishlist?.me ?? club?.me;
  bool get admin => me?.admin ?? false;

  /// Rebuild the service when the active account/token changes and drop any
  /// cached state. Called from the proxy provider's `update` (during build),
  /// so the notify is deferred to after the frame.
  void updateAuth(AuthProvider auth) {
    final base = WishlistService.deriveBaseUrl(auth.activeServerUrl);
    final token = auth.token;
    final key = '${base ?? ''}|${token ?? ''}|${auth.customHeaders}';
    if (key == _key) return;
    _key = key;
    _service = (base == null || token == null || token.isEmpty)
        ? null
        : WishlistService(
            baseUrl: base, token: token, customHeaders: auth.customHeaders);
    wishlist = null;
    club = null;
    wishlistError = null;
    clubError = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  // ── Wishlist loads ──

  /// Load the wishlist. No-op if already cached unless [force] (pull-to-refresh
  /// keeps the cached list visible while refreshing).
  Future<void> loadWishlist({bool force = false}) async {
    final s = _service;
    if (s == null) {
      wishlistError = 'not_connected';
      wishlistLoading = false;
      notifyListeners();
      return;
    }
    if (wishlistLoading) return;
    if (wishlist != null && !force) return;
    wishlistLoading = wishlist == null;
    wishlistError = null;
    notifyListeners();
    try {
      wishlist = await s.getWishlist();
      wishlistError = null;
    } catch (e) {
      wishlistError = e;
    }
    wishlistLoading = false;
    notifyListeners();
  }

  Future<void> refreshWishlist() => loadWishlist(force: true);

  /// Optimistically replace a wanted book (after a vote/claim) without a full
  /// reload.
  void applyWishlistBook(WishlistBook updated) {
    final list = wishlist?.wanted;
    if (list == null) return;
    final i = list.indexWhere((b) => b.id == updated.id);
    if (i < 0) return;
    list[i] = updated;
    notifyListeners();
  }

  void removeWishlistBook(String id) {
    wishlist?.wanted.removeWhere((b) => b.id == id);
    notifyListeners();
  }

  // ── Club loads ──

  Future<void> loadClub({bool force = false}) async {
    final s = _service;
    if (s == null) {
      clubError = 'not_connected';
      clubLoading = false;
      notifyListeners();
      return;
    }
    if (clubLoading) return;
    if (club != null && !force) return;
    clubLoading = club == null;
    clubError = null;
    notifyListeners();
    try {
      club = await s.getClub();
      clubError = null;
    } catch (e) {
      clubError = e;
    }
    clubLoading = false;
    notifyListeners();
  }

  Future<void> refreshClub() => loadClub(force: true);
}
