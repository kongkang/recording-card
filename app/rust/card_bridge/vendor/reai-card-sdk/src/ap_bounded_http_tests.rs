use super::*;
use std::{
    io::{Read, Write},
    net::TcpListener,
};

async fn request(body: String, status: &'static str) -> Result<AccessPointFilePage> {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut bytes = [0_u8; 2048];
        let n = socket.read(&mut bytes).unwrap();
        let head = std::str::from_utf8(&bytes[..n]).unwrap();
        assert!(head.starts_with("GET /api/files?page=1&pageSize=1 HTTP/1.1"));
        let header = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nLocation: http://127.0.0.1:{port}/redirect\r\nConnection: close\r\n\r\n",
            body.len()
        );
        socket.write_all(header.as_bytes()).unwrap();
        // An aborted oversized/redirected body may close before all bytes write.
        let _ = socket.write_all(body.as_bytes());
    });
    let result = AccessPointClient::new("127.0.0.1", port)
        .unwrap()
        .list_files(1, 1)
        .await;
    server.join().unwrap();
    result
}

#[tokio::test]
async fn ap_probe_accepts_bounded_full_sdk_empty_page() {
    let page = request(
        r#"{"total":0,"page":1,"pageSize":1,"totalPages":0,"files":[]}"#.into(),
        "200 OK",
    )
    .await
    .unwrap();
    assert!(page.files.is_empty());
    assert_eq!(page.page_size, 1);
}
#[tokio::test]
async fn ap_probe_refuses_redirect_instead_of_fetching_other_route() {
    let error = request("".into(), "302 Found").await.unwrap_err();
    assert!(matches!(error, SdkError::InvalidFrame(ref message) if message.contains("redirected")));
}
#[tokio::test]
async fn ap_probe_refuses_response_larger_than_one_mib() {
    let error = request(" ".repeat(1024 * 1024 + 1), "200 OK")
        .await
        .unwrap_err();
    assert!(matches!(error, SdkError::InvalidFrame(ref message) if message.contains("1MiB")));
}
#[tokio::test]
async fn ap_probe_refuses_invalid_sdk_shape_and_truncated_json() {
    for body in [
        "{\"files\":[]}",
        "{\"total\":0,\"files\":",
        "<html>not-an-accessory</html>",
    ] {
        assert!(request(body.into(), "200 OK").await.is_err());
    }
}
