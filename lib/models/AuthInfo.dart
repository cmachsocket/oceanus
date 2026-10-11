class AuthInfo {
  AuthInfo({
    required this.cookie,
    required this.loggedIn,
    required this.currentUid,
  });
  AuthInfo.empty() : cookie = const {}, loggedIn = false, currentUid = 0;
  Map<String, String> cookie;
  bool loggedIn;
  int currentUid;
}
