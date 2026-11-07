#ifndef FQ_MEDIA_BRIDGE_H
#define FQ_MEDIA_BRIDGE_H

/**
 * @brief 复用 Rust/C 的分段解密媒体会话，不在磁盘保存明文。
 * @note open 为阻塞 I/O，仅允许工作队列调用；返回字符串由 free 释放一次。
 *       close 与客户端读取可并发，Rust 层负责取消、句柄串行化及生命周期。
 */
char *fq_desktop_media_open(const char *request);
void fq_desktop_media_close(const char *identifier);
void fq_desktop_media_free(char *value);

#endif
