package main

import "core:fmt"
import "core:strings"
import "core:time"

// TODO: Fix rendering.

Console_Message :: struct {
  text: string,
  timestamp: time.Time,
  level: Console_Level,
}

Console_Level :: enum {
  INFO,
  WARNING,
  ERROR,
  LUA,
}

Console :: struct {
  messages: [dynamic]Console_Message,
  visible: bool,
  x, y: f32,
  width: f32,
  height: f32,
  dragging: bool,
  drag_offset: [2]f32,
  max_messages: int,
  auto_scroll: bool,
  scroll_offset: f32,
}

console: Console

console_init :: proc(ctx: ^Console, x, y, width, height: f32) {
  ctx.messages = make([dynamic]Console_Message, 0, 100)
  ctx.visible = false
  ctx.x = x
  ctx.y = y
  ctx.width = width
  ctx.height = height
  ctx.max_messages = 100
  ctx.auto_scroll = true
  ctx.scroll_offset = 0
}

console_cleanup :: proc(ctx: ^Console) {
  for msg in ctx.messages {
    delete(msg.text)
  }
  delete(ctx.messages)
}

console_log :: proc(ctx: ^Console, text: string, level: Console_Level = .INFO) {
  msg := Console_Message {
    text = strings.clone(text),
    timestamp = time.now(),
    level = level,
  }

  append(&ctx.messages, msg)

  if len(ctx.messages) > ctx.max_messages {
    old := ctx.messages[0]
    delete(old.text)
    ordered_remove(&ctx.messages, 0)
  }

  if ctx.auto_scroll {
    ctx.scroll_offset = f32(len(ctx.messages)) * 20
  }
}

console_clear :: proc(ctx: ^Console) {
  for msg in ctx.messages {
    delete(msg.text)
  }
  clear(&ctx.messages)
  ctx.scroll_offset = 0
}

console_render :: proc(ctx: ^Console, ui: ^UI_Context) {
  if !ctx.visible do return

  title_height: f32 = 30
  title_rect := UI_Rect{ctx.x, ctx.y, ctx.width, title_height}

  is_dragging := false
  if point_in_rect(ui.mouse_x, ui.mouse_y, title_rect) {
    if ui.mouse_pressed && !ctx.dragging {
      ctx.dragging = true
      ctx.drag_offset = {ui.mouse_x - ctx.x, ui.mouse_y - ctx.y}
    }
  }

  // Background
  bg_rect := UI_Rect{ctx.x, ctx.y, ctx.width, ctx.height}
  batch_rect(ui, bg_rect, UI_Color{0.1, 0.1, 0.12, 0.95})
  batch_text(ui, "Console Output", ctx.x + 8, ctx.y + 8, ui.style.text_color)

  close_btn_size: f32 = 20
  close_btn_rect := UI_Rect{
    ctx.x + ctx.width - close_btn_size - 5,
    ctx.y + 5,
    close_btn_size,
    close_btn_size,
  }

  if point_in_rect(ui.mouse_x, ui.mouse_y, close_btn_rect) {
    batch_rect(ui, close_btn_rect, UI_Color{0.8, 0.3, 0.3, 1.0})
    if ui.mouse_released {
      ctx.visible = false
    }
  } else {
    batch_rect(ui, close_btn_rect, UI_Color{0.6, 0.2, 0.2, 1.0})
  }
  batch_text(ui, "X", close_btn_rect.x, close_btn_rect.y, UI_Color{0.6, 0.2, 0.2, 1.0})

  clear_btn_rect := UI_Rect {
    ctx.x + ctx.width - close_btn_size * 2 - 10,
    ctx.y + 5,
    close_btn_size,
    close_btn_size,
  }

  if point_in_rect(ui.mouse_x, ui.mouse_y, clear_btn_rect) {
    batch_rect(ui, clear_btn_rect, UI_Color{0.3, 0.5, 0.8, 1.0})
    if ui.mouse_pressed {
      console_clear(ctx)
    }
  } else {
    batch_rect(ui, clear_btn_rect, UI_Color{0.2, 0.4, 0.6, 1.0})
  }
  batch_text(ui, "C", clear_btn_rect.x + 6, clear_btn_rect.y + 3, {1, 1, 1, 1})

  msg_y := ctx.y + title_height + 5
  msg_height := ctx.height - title_height + 5

  line_height: f32 = 18
  visible_lines := int(msg_height / line_height)
  start_idx := max(0, len(ctx.messages) - visible_lines)

  for i in start_idx ..< len(ctx.messages) {
    msg := ctx.messages[i]
    y_pos := msg_y + f32(i - start_idx) * line_height

    text_color: UI_Color
    switch msg.level {
      case .INFO:
        text_color = {0.8, 0.8, 0.85, 1.0}
      case .WARNING:
        text_color = {1.0, 0.8, 0.2, 1.0}
      case .ERROR:
        text_color = {1.0, 0.3, 0.3, 1.0}
      case .LUA:
        text_color = {0.5, 0.8, 1.0, 1.0}
    }

    time_str := fmt.tprintf("[%02d:%02d:%02d]",
    msg.timestamp)

    batch_text(ui, time_str, ctx.x + 8, y_pos, {0.5, 0.5, 0.55, 1.0})

    batch_text(ui, msg.text, ctx.x + 80, y_pos, text_color)
  }
}
