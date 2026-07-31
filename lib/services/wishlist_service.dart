import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// HTTP client for the group audiobook wishlist / book-club server
/// (the Node app on the same host as Audiobookshelf, port 13379).
///
/// Authenticates with the user's existing Audiobookshelf bearer token — the
/// wishlist server validates it against ABS `/api/me` (see auth.js). Modeled on
/// [RmabService]: a bearer-token client on a separate host with typed errors.
class WishlistService {
  WishlistService({
    required String baseUrl,
    required this.token,
    this.customHeaders = const {},
  }) : baseUrl = _trimTrailingSlash(baseUrl);

  /// Wishlist server base URL, no trailing slash (e.g. http://192.168.1.246:13379).
  final String baseUrl;

  /// The Audiobookshelf access token — sent as `Authorization: Bearer`.
  final String token;

  /// Extra headers for auth proxies in front of the server.
  final Map<String, String> customHeaders;

  /// Default wishlist port — the server lives beside ABS on the same host.
  static const int port = 13379;

  static String _trimTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// Derive the wishlist base URL from the ABS server URL by keeping the
  /// scheme+host and swapping the port to [port]. Returns null if the ABS URL
  /// can't be parsed. Callers may override with a stored per-account URL.
  static String? deriveBaseUrl(String? absUrl) {
    if (absUrl == null || absUrl.trim().isEmpty) return null;
    var raw = absUrl.trim();
    if (!raw.contains('://')) raw = 'http://$raw';
    final u = Uri.tryParse(raw);
    if (u == null || u.host.isEmpty) return null;
    return Uri(
      scheme: u.scheme.isEmpty ? 'http' : u.scheme,
      host: u.host,
      port: port,
    ).toString();
  }

  Map<String, String> get _headers => {
        ...customHeaders,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  /// Headers for image requests (e.g. the club cover proxy).
  Map<String, String> get imageHeaders => {
        ...customHeaders,
        'Authorization': 'Bearer $token',
      };

  // ─── Wishlist ──────────────────────────────────────────────────────

  /// GET /api/wishlist — full state (me, users, wanted, features).
  Future<WishlistState> getWishlist() async {
    final res = await _send('GET', '/api/wishlist', label: 'getWishlist');
    return _decode(res, WishlistState.fromJson, label: 'getWishlist');
  }

  /// GET /api/search?q= — search Audible via the server.
  Future<List<WishlistSearchResult>> search(String query) async {
    final uri = Uri.parse('$baseUrl/api/search')
        .replace(queryParameters: {'q': query});
    final res = await _sendUri('GET', uri, label: 'search');
    return _decode(res, (json) {
      return (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(WishlistSearchResult.fromJson)
          .toList();
    }, label: 'search');
  }

  /// POST /api/wishlist {asin} — add a book by ASIN (201) or 409 duplicate.
  Future<void> add(String asin) async {
    await _send('POST', '/api/wishlist',
        body: {'asin': asin}, label: 'add', okCodes: const {200, 201});
  }

  /// POST /api/wishlist/:id/vote {dir} — up/down vote (server handles toggle:
  /// same dir clears, opposite flips). Returns the updated book.
  Future<WishlistBook> vote(String id, int dir) async {
    final res = await _send('POST', '/api/wishlist/$id/vote',
        body: {'dir': dir}, label: 'vote');
    return _decode(res, WishlistBook.fromJson, label: 'vote');
  }

  /// POST /api/wishlist/:id/claim — toggle "I'm grabbing this". Returns the
  /// updated book, or throws [WishlistException] with kind [alreadyClaimed].
  Future<WishlistBook> claim(String id) async {
    final res = await _send('POST', '/api/wishlist/$id/claim', label: 'claim');
    return _decode(res, WishlistBook.fromJson, label: 'claim');
  }

  /// DELETE /api/wishlist/:id — remove (owner/admin only, else 403).
  Future<void> removeItem(String id) async {
    await _send('DELETE', '/api/wishlist/$id', label: 'remove');
  }

  /// GET /api/book/:asin — fresh Audible lookup for the FULL synopsis (the
  /// summary stored at add-time is often just the short blurb).
  Future<WishlistSearchResult> getBook(String asin) async {
    final res = await _send('GET', '/api/book/$asin', label: 'getBook');
    return _decode(res, WishlistSearchResult.fromJson, label: 'getBook');
  }

  // ─── Book Club ─────────────────────────────────────────────────────

  /// GET /api/club — current pick, members+progress, joined, nominations, me.
  Future<ClubState> getClub() async {
    final res = await _send('GET', '/api/club', label: 'getClub');
    return _decode(res, ClubState.fromJson, label: 'getClub');
  }

  /// POST /api/club {itemId} — set the current pick (admin). Null clears it.
  Future<void> setClub(String? itemId) async {
    await _send('POST', '/api/club', body: {'itemId': itemId}, label: 'setClub');
  }

  /// POST /api/club/join — toggle membership; returns the new joined state.
  Future<bool> toggleJoin() async {
    final res = await _send('POST', '/api/club/join', label: 'joinClub');
    final j = jsonDecode(res.body);
    return j is Map && j['joined'] == true;
  }

  /// POST /api/club/goal {endDate: 'YYYY-MM-DD'|null} — finish-by goal (admin).
  Future<void> setClubGoal(String? endDate) async {
    await _send('POST', '/api/club/goal',
        body: {'endDate': endDate}, label: 'clubGoal');
  }

  /// POST /api/club/nominate {itemId} — nominate for the next pick.
  Future<void> nominate(String itemId) async {
    await _send('POST', '/api/club/nominate',
        body: {'itemId': itemId}, label: 'nominate', okCodes: const {200, 201});
  }

  /// POST /api/club/nominations/:id/vote — toggle your extra vote.
  Future<void> voteNomination(String id) async {
    await _send('POST', '/api/club/nominations/$id/vote', label: 'voteNom');
  }

  /// DELETE /api/club/nominations/:id — remove a nomination (owner/admin).
  Future<void> removeNomination(String id) async {
    await _send('DELETE', '/api/club/nominations/$id', label: 'removeNom');
  }

  /// GET /api/club/search?q= — search the ABS library for a pick/nominee.
  Future<List<ClubLibraryItem>> clubSearch(String query) async {
    final uri = Uri.parse('$baseUrl/api/club/search')
        .replace(queryParameters: {'q': query});
    final res = await _sendUri('GET', uri, label: 'clubSearch');
    return _decode(res, (json) {
      return (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClubLibraryItem.fromJson)
          .toList();
    }, label: 'clubSearch');
  }

  /// GET /api/club/item?item= — description + ASIN for a nominee.
  Future<ClubItemDetail> clubItemDetail(String itemId) async {
    final uri = Uri.parse('$baseUrl/api/club/item')
        .replace(queryParameters: {'item': itemId});
    final res = await _sendUri('GET', uri, label: 'clubItem');
    return _decode(res, ClubItemDetail.fromJson, label: 'clubItem');
  }

  /// Cover proxy URL for the current club book (server-side ABS token).
  String clubCoverUrl(String itemId) =>
      '$baseUrl/api/club/cover?item=${Uri.encodeComponent(itemId)}';

  // ─── Shared transport ──────────────────────────────────────────────

  Future<http.Response> _send(String method, String path,
      {Map<String, dynamic>? body,
      required String label,
      Set<int> okCodes = const {200}}) {
    return _sendUri(method, Uri.parse('$baseUrl$path'),
        body: body, label: label, okCodes: okCodes);
  }

  Future<http.Response> _sendUri(String method, Uri uri,
      {Map<String, dynamic>? body,
      required String label,
      Set<int> okCodes = const {200}}) async {
    debugPrint('[Wishlist] $label $method $uri');
    http.Response res;
    try {
      final req = http.Request(method, uri);
      req.headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      res = await http.Response.fromStream(streamed);
      debugPrint('[Wishlist] $label <- ${res.statusCode} (${res.body.length}b)');
    } on TimeoutException {
      throw WishlistException(WishlistErrorKind.network, 'Request timed out');
    } on SocketException catch (e) {
      throw WishlistException(WishlistErrorKind.network, e.message);
    } on http.ClientException catch (e) {
      throw WishlistException(WishlistErrorKind.network, e.message);
    } catch (e) {
      throw WishlistException(WishlistErrorKind.network, e.toString());
    }

    if (okCodes.contains(res.statusCode)) return res;
    if (res.statusCode == 401) {
      throw WishlistException(
          WishlistErrorKind.unauthorized, _msg(res) ?? 'Unauthorized');
    }
    if (res.statusCode == 403) {
      throw WishlistException(
          WishlistErrorKind.forbidden, _named(res) ?? 'not_owner');
    }
    if (res.statusCode == 409) {
      throw WishlistException(
          WishlistErrorKind.conflict, _named(res) ?? 'conflict');
    }
    throw WishlistException(WishlistErrorKind.server,
        _msg(res) ?? 'Server returned HTTP ${res.statusCode}');
  }

  T _decode<T>(http.Response res, T Function(Map<String, dynamic>) builder,
      {required String label}) {
    try {
      return builder(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[Wishlist] $label parse error: $e');
      throw WishlistException(
          WishlistErrorKind.parse, 'Unexpected response from server');
    }
  }

  String? _msg(http.Response res) {
    try {
      final b = jsonDecode(res.body);
      if (b is Map) {
        final m = b['message'] ?? b['error'];
        if (m is String && m.isNotEmpty) return m;
      }
    } catch (_) {}
    return null;
  }

  /// The server's machine-readable `error` code (e.g. `already_claimed`).
  String? _named(http.Response res) {
    try {
      final b = jsonDecode(res.body);
      if (b is Map && b['error'] is String) return b['error'] as String;
    } catch (_) {}
    return null;
  }
}

// ─── Errors ───────────────────────────────────────────────────────────

enum WishlistErrorKind { network, unauthorized, forbidden, conflict, server, parse }

class WishlistException implements Exception {
  WishlistException(this.kind, this.message);
  final WishlistErrorKind kind;
  final String message;

  @override
  String toString() => 'WishlistException($kind): $message';
}

// ─── Models ───────────────────────────────────────────────────────────

class WishlistMe {
  const WishlistMe({required this.name, required this.admin});
  final String name;
  final bool admin;

  static WishlistMe? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    if (name is! String) return null;
    return WishlistMe(name: name, admin: json['admin'] == true);
  }
}

class WishlistState {
  WishlistState({
    required this.me,
    required this.users,
    required this.wanted,
    required this.features,
  });

  final WishlistMe? me;
  final List<String> users;
  final List<WishlistBook> wanted;
  final List<WishlistBook> features;

  factory WishlistState.fromJson(Map<String, dynamic> json) => WishlistState(
        me: WishlistMe.fromJson(json['me']),
        users: (json['users'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(),
        wanted: (json['wanted'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(WishlistBook.fromJson)
            .toList(),
        features: (json['features'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(WishlistBook.fromJson)
            .toList(),
      );
}

class WishlistBook {
  WishlistBook({
    required this.id,
    required this.asin,
    required this.title,
    required this.author,
    this.narrator,
    this.series,
    this.seriesPosition,
    this.lengthMin,
    this.releaseDate,
    this.coverUrl,
    this.summary,
    required this.addedBy,
    this.votes = const {},
    this.claimedBy,
  });

  final String id;
  final String asin;
  final String title;
  final String author;
  final String? narrator;
  final String? series;
  final String? seriesPosition;
  final int? lengthMin;
  final String? releaseDate;
  final String? coverUrl;
  final String? summary;
  final String addedBy;
  final Map<String, int> votes;
  final String? claimedBy;

  /// Net score = sum of vote directions.
  int get score => votes.values.fold(0, (a, b) => a + b);

  bool get isClaimed => (claimedBy ?? '').isNotEmpty;

  /// This user's current vote (1, -1, or 0), matched case-insensitively.
  int myVote(String? me) {
    if (me == null) return 0;
    final lower = me.toLowerCase();
    for (final e in votes.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return 0;
  }

  factory WishlistBook.fromJson(Map<String, dynamic> json) {
    final rawVotes = json['votes'];
    final votes = <String, int>{};
    if (rawVotes is Map) {
      rawVotes.forEach((k, v) {
        final n = v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
        if (k is String && n != null) votes[k] = n;
      });
    }
    return WishlistBook(
      id: (json['id'] ?? '') as String,
      asin: (json['asin'] ?? '') as String,
      title: (json['title'] ?? '') as String,
      author: (json['author'] ?? '') as String,
      narrator: json['narrator'] as String?,
      series: json['series'] as String?,
      seriesPosition: json['seriesPosition']?.toString(),
      lengthMin: _asInt(json['lengthMin']),
      releaseDate: json['releaseDate'] as String?,
      coverUrl: json['coverUrl'] as String?,
      summary: json['summary'] as String?,
      addedBy: (json['addedBy'] ?? '') as String,
      votes: votes,
      claimedBy: json['claimedBy'] as String?,
    );
  }
}

class WishlistSearchResult {
  WishlistSearchResult({
    required this.asin,
    required this.title,
    required this.author,
    this.narrator,
    this.series,
    this.seriesPosition,
    this.lengthMin,
    this.releaseDate,
    this.coverUrl,
    this.summary,
    this.owned = false,
    this.wishlisted = false,
  });

  final String asin;
  final String title;
  final String author;
  final String? narrator;
  final String? series;
  final String? seriesPosition;
  final int? lengthMin;
  final String? releaseDate;
  final String? coverUrl;
  final String? summary;
  final bool owned;
  final bool wishlisted;

  factory WishlistSearchResult.fromJson(Map<String, dynamic> json) =>
      WishlistSearchResult(
        asin: (json['asin'] ?? '') as String,
        title: (json['title'] ?? '') as String,
        author: (json['author'] ?? '') as String,
        narrator: json['narrator'] as String?,
        series: json['series'] as String?,
        seriesPosition: json['seriesPosition']?.toString(),
        lengthMin: _asInt(json['lengthMin']),
        releaseDate: json['releaseDate'] as String?,
        coverUrl: json['coverUrl'] as String?,
        summary: json['summary'] as String?,
        owned: json['owned'] == true,
        wishlisted: json['wishlisted'] == true,
      );
}

// ─── Book Club models ─────────────────────────────────────────────────

class ClubState {
  ClubState({
    required this.me,
    required this.book,
    required this.members,
    required this.joined,
    required this.nominations,
  });

  final WishlistMe? me;
  final ClubBook? book;
  final List<ClubMember> members;
  final bool joined;
  final List<ClubNomination> nominations;

  bool get admin => me?.admin ?? false;

  factory ClubState.fromJson(Map<String, dynamic> j) => ClubState(
        me: WishlistMe.fromJson(j['me']),
        book: j['book'] is Map<String, dynamic>
            ? ClubBook.fromJson(j['book'] as Map<String, dynamic>)
            : null,
        members: (j['members'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ClubMember.fromJson)
            .toList(),
        joined: j['joined'] == true,
        nominations: (j['nominations'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ClubNomination.fromJson)
            .toList(),
      );
}

class ClubBook {
  ClubBook({
    required this.itemId,
    required this.title,
    required this.author,
    this.narrator,
    this.series,
    this.durationSec,
    this.setBy,
    this.endDate,
  });

  final String itemId;
  final String title;
  final String author;
  final String? narrator;
  final String? series;
  final double? durationSec;
  final String? setBy;
  final String? endDate;

  factory ClubBook.fromJson(Map<String, dynamic> j) => ClubBook(
        itemId: (j['itemId'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        narrator: j['narrator'] as String?,
        series: j['series'] as String?,
        durationSec: (j['duration'] as num?)?.toDouble(),
        setBy: j['setBy'] as String?,
        endDate: j['endDate'] as String?,
      );
}

class ClubMember {
  ClubMember({required this.name, required this.progress, required this.isFinished});
  final String name;
  final double progress; // 0..1
  final bool isFinished;

  factory ClubMember.fromJson(Map<String, dynamic> j) => ClubMember(
        name: (j['name'] ?? '') as String,
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        isFinished: j['isFinished'] == true,
      );
}

class ClubNomination {
  ClubNomination({
    required this.id,
    required this.itemId,
    required this.title,
    required this.author,
    this.durationSec,
    required this.submittedBy,
    required this.score,
    required this.mine,
    required this.voted,
  });

  final String id;
  final String itemId;
  final String title;
  final String author;
  final double? durationSec;
  final String submittedBy;
  final int score;
  final bool mine;
  final bool voted;

  factory ClubNomination.fromJson(Map<String, dynamic> j) => ClubNomination(
        id: (j['id'] ?? '') as String,
        itemId: (j['itemId'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        durationSec: (j['duration'] as num?)?.toDouble(),
        submittedBy: (j['submittedBy'] ?? '') as String,
        score: _asInt(j['score']) ?? 0,
        mine: j['mine'] == true,
        voted: j['voted'] == true,
      );
}

class ClubLibraryItem {
  ClubLibraryItem({
    required this.id,
    required this.title,
    required this.author,
    this.narrator,
    this.series,
    this.durationSec,
  });

  final String id;
  final String title;
  final String author;
  final String? narrator;
  final String? series;
  final double? durationSec;

  factory ClubLibraryItem.fromJson(Map<String, dynamic> j) => ClubLibraryItem(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        author: (j['author'] ?? '') as String,
        narrator: j['narrator'] as String?,
        series: j['series'] as String?,
        durationSec: (j['duration'] as num?)?.toDouble(),
      );
}

class ClubItemDetail {
  ClubItemDetail({this.summary, this.asin});
  final String? summary;
  final String? asin;

  factory ClubItemDetail.fromJson(Map<String, dynamic> j) => ClubItemDetail(
        summary: j['summary'] as String?,
        asin: j['asin'] as String?,
      );
}

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
