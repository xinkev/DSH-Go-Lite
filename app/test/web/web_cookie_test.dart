import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a held cookie is bound to the host the app used', () {
    final cookie = webViewCookie(Uri.parse('http://192.168.1.5:3081/'), 'dsh_pocket_token', 'v1.abc');
    expect(cookie?.name, 'dsh_pocket_token');
    expect(cookie?.value, 'v1.abc');
    expect(cookie?.domain, '192.168.1.5');
    expect(cookie?.path, '/');
  });

  test('an empty pair or host carries no cookie', () {
    expect(webViewCookie(Uri.parse('http://host:3081/'), ' ', 'v1'), isNull);
    expect(webViewCookie(Uri.parse('http://host:3081/'), 'name', '  '), isNull);
    expect(webViewCookie(Uri.parse('http:///'), 'name', 'v1'), isNull);
  });
}
