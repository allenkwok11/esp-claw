# ESP32-S3 屏幕图片显示参考

本文是给新项目和同事参考的一份独立说明，聚焦“ESP32-S3 板子如何把图片显示到屏幕上”。

当前工程里，图片显示主要分成两层：

1. 板级层负责把 LCD/OLED 面板初始化起来。
2. 显示层负责把 `lv_img_dsc_t` 图片数据真正画到屏幕上。

如果你要在 ESP32-S3 原始硬件上做新项目，最重要的是先确认三件事：

- 屏幕走什么总线：SPI / RGB / MIPI / 8080 / I2C OLED
- 屏幕芯片是什么：ILI9341 / ST7789 / SSD1306 / 其他
- 图片数据如何进入显示层：`SetPreviewImage()`、`SetEmotion()`、`SetIcon()`

---

## 1. 当前 ESP32-S3 默认板子的显示入口

当前工程默认配置的是 `CONFIG_BOARD_TYPE_HEYSANTA`，对应板级实现文件是：

- [main/boards/HeySanta/HeySanta.cc](../main/boards/HeySanta/HeySanta.cc)
- [main/boards/HeySanta/config.h](../main/boards/HeySanta/config.h)

这块板子的屏幕初始化代码在 `InitializeSt7789Display()`，虽然函数名里写的是 ST7789，实际创建的是 ILI9341 面板：

```cpp
void InitializeSt7789Display() {
    esp_lcd_panel_io_handle_t panel_io = nullptr;
    esp_lcd_panel_handle_t panel = nullptr;

    esp_lcd_panel_io_spi_config_t io_config = {};
    io_config.cs_gpio_num = GPIO_NUM_NC;
    io_config.dc_gpio_num = GPIO_NUM_39;
    io_config.spi_mode = 0;
    io_config.pclk_hz = 40 * 1000 * 1000;
    io_config.trans_queue_depth = 10;
    io_config.lcd_cmd_bits = 8;
    io_config.lcd_param_bits = 8;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi(SPI3_HOST, &io_config, &panel_io));

    esp_lcd_panel_dev_config_t panel_config = {};
    panel_config.reset_gpio_num = GPIO_NUM_NC;
    panel_config.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
    panel_config.bits_per_pixel = 16;
    panel_config.vendor_config = NULL;
    ESP_ERROR_CHECK(esp_lcd_new_panel_ili9341(panel_io, &panel_config, &panel));

    esp_lcd_panel_reset(panel);
    esp_lcd_panel_init(panel);
    esp_lcd_panel_invert_color(panel, false);
    esp_lcd_panel_swap_xy(panel, DISPLAY_SWAP_XY);
    esp_lcd_panel_mirror(panel, DISPLAY_MIRROR_X, DISPLAY_MIRROR_Y);
    esp_lcd_panel_set_gap(panel, 0, 0);
    esp_lcd_panel_disp_on_off(panel, true);

    display_ = new anim::EmojiWidget(panel, panel_io);
}
```

对应的关键 GPIO 在 [main/boards/HeySanta/config.h](../main/boards/HeySanta/config.h) 里：

```cpp
#define DISPLAY_WIDTH   320
#define DISPLAY_HEIGHT  240
#define DISPLAY_MIRROR_X true
#define DISPLAY_MIRROR_Y false
#define DISPLAY_SWAP_XY true

#define DISPLAY_OFFSET_X  0
#define DISPLAY_OFFSET_Y  0

#define DISPLAY_BACKLIGHT_PIN GPIO_NUM_42
#define DISPLAY_BACKLIGHT_OUTPUT_INVERT true
```

如果你只关心“屏幕如何被点亮”，这两个文件就是最直接的入口。

---

## 2. 显示层的统一接口

工程把所有屏幕抽象成同一个 `Display` 接口：

```cpp
class Display {
public:
    virtual void SetStatus(const char* status);
    virtual void ShowNotification(const char* notification, int duration_ms = 3000);
    virtual void SetEmotion(const char* emotion);
    virtual void SetChatMessage(const char* role, const char* content);
    virtual void SetIcon(const char* icon);
    virtual void SetPreviewImage(const lv_img_dsc_t* image);
    virtual void SetTheme(const std::string& theme_name);
    virtual void UpdateStatusBar(bool update_all = false);
    virtual void SetPowerSaveMode(bool on);
};
```

这个接口的意义很重要：

- 业务层不用关心屏幕是 SPI 还是 OLED
- 只要拿到 `Board::GetInstance().GetDisplay()`，就能调用统一显示接口
- 你要显示图片，最终也是走 `SetPreviewImage()`

相关文件：

- [main/display/display.h](../main/display/display.h)
- [main/display/display.cc](../main/display/display.cc)

---

## 3. 图片是怎么真正显示出来的

### 3.1 通用 LCD 显示实现

在普通 LCD 显示实现里，`SetPreviewImage()` 会把 `lv_img_dsc_t` 作为图片源挂到 LVGL 对象上：

```cpp
void LcdDisplay::SetPreviewImage(const lv_img_dsc_t* img_dsc) {
    DisplayLockGuard lock(this);
    if (content_ == nullptr) {
        return;
    }

    if (img_dsc != nullptr) {
        lv_image_set_src(preview_image_, img_dsc);
        lv_obj_clear_flag(preview_image_, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(preview_image_, LV_OBJ_FLAG_HIDDEN);
    }
}
```

完整实现还会做：

- 复制图片数据，避免原始指针失效
- 根据图片宽高设置缩放
- 在对象删除时释放动态分配的图片内存

相关文件：

- [main/display/lcd_display.cc](../main/display/lcd_display.cc)

### 3.2 OLED 显示实现

OLED 也通过统一的显示抽象进入 LVGL，只是底层面板创建和 UI 布局不同：

```cpp
OledDisplay::OledDisplay(esp_lcd_panel_io_handle_t panel_io, esp_lcd_panel_handle_t panel,
    int width, int height, bool mirror_x, bool mirror_y, DisplayFonts fonts)
    : panel_io_(panel_io), panel_(panel), fonts_(fonts) {
    width_ = width;
    height_ = height;

    lvgl_port_cfg_t port_cfg = ESP_LVGL_PORT_INIT_CONFIG();
    port_cfg.task_priority = 1;
    port_cfg.task_stack = 6144;
    port_cfg.timer_period_ms = 50;
    lvgl_port_init(&port_cfg);
}
```

相关文件：

- [main/display/oled_display.cc](../main/display/oled_display.cc)

---

## 4. 图片来源之一：摄像头预览

工程里已经有一条“摄像头帧 -> 图片对象 -> 屏幕显示”的链路。

在板级摄像头代码里，图像先被填到一个 `lv_img_dsc_t` 结构，然后送到显示层：

```cpp
preview_image_.header.magic = LV_IMAGE_HEADER_MAGIC;
preview_image_.header.cf = LV_COLOR_FORMAT_RGB565;
preview_image_.header.flags = LV_IMAGE_FLAGS_ALLOCATED | LV_IMAGE_FLAGS_MODIFIABLE;
preview_image_.header.stride = preview_image_.header.w * 2;
preview_image_.data_size = preview_image_.header.w * preview_image_.header.h * 2;
preview_image_.data = (uint8_t*)heap_caps_malloc(preview_image_.data_size, MALLOC_CAP_SPIRAM);

display->SetPreviewImage(&preview_image_);
```

相关文件：

- [main/boards/common/esp32_camera.cc](../main/boards/common/esp32_camera.cc)
- [main/boards/common/esp32_camera.h](../main/boards/common/esp32_camera.h)

如果你想让屏幕显示“图片”，这条链路是最标准的模板：

1. 准备 `lv_img_dsc_t`
2. 填好 `header.w`、`header.h`、`header.cf`
3. 填好 `data` 和 `data_size`
4. 调用 `display->SetPreviewImage(&preview_image_)`

---

## 5. 另外两条常用显示路径：表情与图标

### 5.1 表情显示

应用层会通过 `SetEmotion()` 控制表情：

```cpp
display->SetEmotion(emotion_str.c_str());
```

对应显示层会把表情映射成图标或动画资源。

相关文件：

- [main/application.cc](../main/application.cc)
- [main/display/display.cc](../main/display/display.cc)
- [main/boards/HeySanta/emoji_display.cc](../main/boards/HeySanta/emoji_display.cc)

### 5.2 图标显示

比如升级时会切换成下载图标：

```cpp
display->SetIcon(FONT_AWESOME_DOWNLOAD);
```

这类图标一般不是“图片文件”，而是字体图标字符。

相关文件：

- [main/application.cc](../main/application.cc)
- [main/display/display.cc](../main/display/display.cc)

---

## 6. 图片显示的完整调用链

你可以按下面这条链路理解：

```text
业务层 / 摄像头 / 其他来源
    -> Display::SetPreviewImage()
    -> LcdDisplay::SetPreviewImage() 或 OledDisplay 的对应实现
    -> lv_image_set_src()
    -> LVGL 刷新
    -> esp_lcd_panel_draw_bitmap() / 驱动提交
    -> LCD/OLED 真正显示
```

对 HeySanta 来说，当前板子更偏向“动画表情显示”，不是一个标准静态图片框架；但只要你把 `lv_img_dsc_t` 接到 `SetPreviewImage()`，这一套就能用。

---

## 7. 你新项目里最值得复用的代码片段

### 7.1 板级显示初始化

来自 [main/boards/HeySanta/HeySanta.cc](../main/boards/HeySanta/HeySanta.cc)：

```cpp
ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi(SPI3_HOST, &io_config, &panel_io));
ESP_ERROR_CHECK(esp_lcd_new_panel_ili9341(panel_io, &panel_config, &panel));
display_ = new anim::EmojiWidget(panel, panel_io);
```

### 7.2 显示统一入口

来自 [main/display/display.h](../main/display/display.h)：

```cpp
virtual void SetPreviewImage(const lv_img_dsc_t* image);
virtual void SetEmotion(const char* emotion);
virtual void SetIcon(const char* icon);
```

### 7.3 图片对象显示

来自 [main/display/lcd_display.cc](../main/display/lcd_display.cc)：

```cpp
lv_image_set_src(preview_image_, img_dsc);
lv_obj_clear_flag(preview_image_, LV_OBJ_FLAG_HIDDEN);
```

### 7.4 摄像头预览转图片结构

来自 [main/boards/common/esp32_camera.cc](../main/boards/common/esp32_camera.cc)：

```cpp
preview_image_.header.cf = LV_COLOR_FORMAT_RGB565;
preview_image_.data_size = preview_image_.header.w * preview_image_.header.h * 2;
display->SetPreviewImage(&preview_image_);
```

---

## 8. 给同事的结论

如果只是问“ESP32-S3 上要让屏幕显示图片，代码该看哪里”，答案是：

- 先看板级屏幕初始化：[main/boards/HeySanta/HeySanta.cc](../main/boards/HeySanta/HeySanta.cc)
- 再看统一显示接口：[main/display/display.h](../main/display/display.h)
- 再看图片显示实现：[main/display/lcd_display.cc](../main/display/lcd_display.cc)
- 如果图片来自摄像头，再看：[main/boards/common/esp32_camera.cc](../main/boards/common/esp32_camera.cc)

如果你愿意，我下一步可以继续给你出一份“新 ESP32-S3 项目专用显示模板”，内容会更偏工程化：

- 仅保留屏幕显示的最小 `board_xxx.cc`
- 一份可直接改 GPIO 的 `config.h`
- 一个“开机先显示静态图”的最小示例