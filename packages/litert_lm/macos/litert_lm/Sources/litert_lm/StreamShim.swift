import CLiteRTLM
import Foundation

// Прослойка для потокового ответа.
//
// litert_lm_conversation_send_message_stream вызывает колбэк из своего потока,
// и кусок ответа действителен только во время вызова. Dart-колбэк
// (NativeCallable.listener) срабатывает позже — поэтому здесь куски копируются
// в очередь, а Dart забирает их опросом через znaika_llm_stream_poll.

private final class StreamState {
    let lock = NSLock()
    /// Куски ответа как есть: каждый — JSON-объект сообщения.
    var chunks: [String] = []
    var done = false
    var error: String?
}

private let onChunk: LiteRtLmStreamCallback = { data, chunk in
    guard let data, let chunk else { return }
    let state = Unmanaged<StreamState>.fromOpaque(data).takeUnretainedValue()
    state.lock.lock()
    defer { state.lock.unlock() }
    if let error = litert_lm_stream_chunk_get_error(chunk) {
        state.error = String(cString: error)
        state.done = true
        return
    }
    if let text = litert_lm_stream_chunk_get_text(chunk), text.pointee != 0 {
        state.chunks.append(String(cString: text))
    }
    if litert_lm_stream_chunk_is_final(chunk) {
        state.done = true
    }
}

/// Запускает потоковый ответ. Возвращает дескриптор потока или NULL при ошибке.
@_cdecl("znaika_llm_stream_start")
public func znaikaLlmStreamStart(
    _ conversation: OpaquePointer?,
    _ messageJson: UnsafePointer<CChar>?,
    _ optionalArgs: OpaquePointer?
) -> UnsafeMutableRawPointer? {
    let handle = Unmanaged.passRetained(StreamState()).toOpaque()
    let status = litert_lm_conversation_send_message_stream(conversation, messageJson, "{}", optionalArgs, onChunk, handle)
    guard status == 0 else {
        Unmanaged<StreamState>.fromOpaque(handle).release()
        return nil
    }
    return handle
}

/// Забирает накопленное.
/// 0 — новых данных нет; 1 — в *out JSON-массив кусков; 2 — поток завершён
/// (данных больше не будет); 3 — ошибка, в *out её текст.
/// Строку из *out освобождать через znaika_llm_free.
@_cdecl("znaika_llm_stream_poll")
public func znaikaLlmStreamPoll(
    _ handle: UnsafeMutableRawPointer?,
    _ out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let handle, let out else { return 3 }
    let state = Unmanaged<StreamState>.fromOpaque(handle).takeUnretainedValue()
    state.lock.lock()
    defer { state.lock.unlock() }
    if !state.chunks.isEmpty {
        out.pointee = strdup("[" + state.chunks.joined(separator: ",") + "]")
        state.chunks.removeAll()
        return 1
    }
    if let error = state.error {
        out.pointee = strdup(error)
        return 3
    }
    return state.done ? 2 : 0
}

/// Освобождает дескриптор. Вызывать только после того, как poll вернул 2 или 3.
@_cdecl("znaika_llm_stream_free")
public func znaikaLlmStreamFree(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<StreamState>.fromOpaque(handle).release()
}

@_cdecl("znaika_llm_free")
public func znaikaLlmFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}
