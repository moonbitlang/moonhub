///|
test "attachment filenames cannot inject download headers" {
  assert_eq(attachment_disposition("image.png", inline=true), "inline")
  assert_eq(
    attachment_disposition("报告 \"a\".pdf", inline=false),
    "attachment; filename=\"attachment\"; filename*=UTF-8''%E6%8A%A5%E5%91%8A%20%22a%22.pdf",
  )
  let header = attachment_disposition(
    "x\r\nContent-Type: text/html",
    inline=false,
  )
  assert_false(header.contains("\r"))
  assert_false(header.contains("\n"))
  assert_true(header.contains("%0D%0A"))
}
