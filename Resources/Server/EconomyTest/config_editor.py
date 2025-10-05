import sys
import json
import os
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QGridLayout, QComboBox, QLabel, QLineEdit, QPushButton,
    QScrollArea, QGroupBox, QMessageBox, QCheckBox
)
from PySide6.QtCore import Qt
from PySide6.QtGui import QIntValidator

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILENAME = os.path.join(SCRIPT_DIR, "config.json")
LANG_DIR = os.path.join(SCRIPT_DIR, "lang")

FALLBACK_DEFAULTS = {
    "features": {
        "roleplay_enabled": True, "money_per_minute_enabled": True, "cool_message_enabled": True,
        "speeding_bonus_enabled": True, "zigzag_bonus_enabled": True, "police_features_enabled": True
    },
    "general": {"autosave_interval_ms": 120000},
    "money": {
        "money_per_minute_interval_ms": 60000, "money_per_minute_amount": 10,
        "starting_money": 3333, "cool_message_interval_ms": 30000
    },
    "civilian": {
        "speeding_limit_kmh": 100, "speeding_bonus_duration_ms": 60000, "speeding_cooldown_ms": 200000,
        "speeding_bonus_per_second": 1, "zigzag_bonus_duration_ms": 120000, "zigzag_cooldown_ms": 200000,
        "zigzag_final_bonus_amount": 50, "zigzag_prorated_bonus": 5, "min_speed_kmh_for_zigzag": 10,
        "zigzag_min_turns": 5, "wanted_fail_penalty": 50
    },
    "police": {
        "police_proximity_range_m": 150, "busted_range_m": 20, "busted_stop_time_ms": 7000,
        "busted_speed_limit_kmh": 5, "police_bonus_per_second": 2, "bust_bonus_amount": 100
    }
}

STYLESHEET = """
    #MainWindow, #ScrollContent {
        background-color: #F0F2F5; /* Light grey background */
    }
    QWidget {
        color: #333333; /* Dark grey text */
        font-family: 'Segoe UI', Arial, sans-serif;
    }
    #TitleLabel {
        font-size: 38px;
        font-weight: 900;
        color: #007BFF; /* Bright blue */
    }
    QGroupBox {
        font-size: 16px;
        font-weight: bold;
        color: #28A745; /* Green */
        background-color: #FFFFFF;
        border: 1px solid #DDDDDD;
        border-radius: 12px;
        margin-top: 15px; /* Give space for the title */
    }
    QGroupBox::title {
        subcontrol-origin: margin;
        subcontrol-position: top center;
        padding: 0 10px;
        background-color: #FFFFFF;
        border-radius: 5px;
    }
    /* Label for entry fields */
    #EntryLabel {
        font-size: 13px;
        font-weight: bold;
        color: #555555;
        padding-bottom: 3px;
    }
    QLineEdit, QComboBox {
        background-color: #F0F2F5;
        border: 1px solid #CED4DA;
        border-radius: 8px;
        padding: 8px;
        font-size: 14px;
        font-weight: 500;
    }
    QLineEdit:focus, QComboBox:focus {
        border: 2px solid #007BFF;
    }
    QComboBox QAbstractItemView {
        background-color: #FFFFFF;
        border: 1px solid #007BFF;
        color: #333333;
    }
    QCheckBox {
        font-size: 14px;
        font-weight: bold;
        color: #0056b3;
    }
    QPushButton {
        background-color: #007BFF;
        color: #FFFFFF;
        font-size: 16px;
        font-weight: bold;
        padding: 12px 25px;
        border-radius: 8px;
        border: none;
    }
    QPushButton:hover {
        background-color: #0056b3;
    }
    QPushButton#ResetButton {
        background-color: #DC3545; /* Red */
    }
    QPushButton#ResetButton:hover {
        background-color: #c82333;
    }
    /* Style for visually weakening disabled widgets */
    QWidget:disabled {
        opacity: 0.45;
    }
    QMessageBox {
        background-color: #FFFFFF;
    }
"""

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setObjectName("MainWindow")
        
        self.widgets = {}
        self.translations = {}
        self.lang_map = {}
        self.roleplay_dependent_widgets = []
        self.current_lang = "en"
        
        self.load_all_languages()
        self.init_ui()
        self.load_config()
        
        self.change_language("en")

    def init_ui(self):
        self.setWindowTitle("UIMPIT Config Editor")
        self.resize(1000, 800)
        self.setStyleSheet(STYLESHEET)

        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        self.main_layout = QVBoxLayout(main_widget)
        self.main_layout.setContentsMargins(25, 20, 25, 20)

        self.main_layout.addLayout(self.create_header())

        scroll_area = QScrollArea()
        scroll_area.setWidgetResizable(True)
        scroll_area.setStyleSheet("border: none;")
        self.main_layout.addWidget(scroll_area)
        
        scroll_content = QWidget()
        scroll_content.setObjectName("ScrollContent")
        scroll_area.setWidget(scroll_content)
        
        self.content_layout = QVBoxLayout(scroll_content)

        self.content_layout.addWidget(self.create_features_settings())
        
        main_grid = QGridLayout()
        main_grid.setSpacing(20)
        main_grid.addWidget(self.create_general_settings(), 0, 0)
        main_grid.addWidget(self.create_money_settings(), 0, 1)
        self.content_layout.addLayout(main_grid)

        self.content_layout.addWidget(self.create_civilian_settings())
        self.content_layout.addWidget(self.create_police_settings())
        self.content_layout.addStretch()

        self.main_layout.addLayout(self.create_footer())

    def create_header(self):
        header_layout = QHBoxLayout()
        title_label = QLabel("UIMPIT")
        title_label.setObjectName("TitleLabel")
        header_layout.addWidget(title_label)
        header_layout.addStretch()
        if self.lang_map:
            self.lang_combobox = QComboBox()
            self.lang_combobox.addItems(self.lang_map.keys())
            self.lang_combobox.currentTextChanged.connect(self.on_lang_changed)
            header_layout.addWidget(self.lang_combobox)
        return header_layout

    def create_footer(self):
        footer_layout = QHBoxLayout()
        footer_layout.addStretch()
        self.reset_button = QPushButton()
        self.reset_button.setObjectName("ResetButton")
        self.reset_button.clicked.connect(self.reset_to_defaults)
        self.save_button = QPushButton()
        self.save_button.clicked.connect(self.save_config)
        footer_layout.addWidget(self.reset_button)
        footer_layout.addWidget(self.save_button)
        return footer_layout

    def create_labeled_entry(self, category, key, label_key):
        """Creates a self-contained widget with a label above a line edit."""
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(4)
        
        label = QLabel()
        label.setObjectName("EntryLabel") 
        self.widgets[f"label_{label_key}"] = label
        
        entry = QLineEdit()
        entry.setValidator(QIntValidator(0, 999999999))
        if category not in self.widgets:
            self.widgets[category] = {}
        self.widgets[category][key] = entry
        
        layout.addWidget(label)
        layout.addWidget(entry)
        return widget

    def create_group_box(self, title_key, dependent=False):
        """Helper to create and track a QGroupBox."""
        group_box = QGroupBox()
        self.widgets[title_key] = group_box
        if dependent:
            self.roleplay_dependent_widgets.append(group_box)
        
        internal_layout = QGridLayout(group_box)
        internal_layout.setContentsMargins(15, 25, 15, 15) 
        internal_layout.setSpacing(15)
        
        return group_box, internal_layout

    def create_features_settings(self):
        group_box, grid = self.create_group_box('features_settings_title')

        cb_roleplay = self._add_checkbox_to_grid(grid, 0, 0, 'features', 'roleplay_enabled')
        cb_roleplay.stateChanged.connect(self.apply_feature_dependencies)
        
        self.roleplay_dependent_widgets.append(
            self._add_checkbox_to_grid(grid, 1, 0, 'features', 'speeding_bonus_enabled')
        )
        self.roleplay_dependent_widgets.append(
            self._add_checkbox_to_grid(grid, 1, 1, 'features', 'zigzag_bonus_enabled')
        )
        self.roleplay_dependent_widgets.append(
            self._add_checkbox_to_grid(grid, 1, 2, 'features', 'police_features_enabled')
        )

        self._add_checkbox_to_grid(grid, 0, 1, 'features', 'money_per_minute_enabled')
        self._add_checkbox_to_grid(grid, 0, 2, 'features', 'cool_message_enabled')
        
        return group_box

    def _add_checkbox_to_grid(self, grid_layout, row, col, category, key):
        """Creates and adds a checkbox to the widget map and a grid."""
        checkbox = QCheckBox()
        self.widgets[f"label_{key}"] = checkbox
        if category not in self.widgets:
            self.widgets[category] = {}
        self.widgets[category][key] = checkbox
        grid_layout.addWidget(checkbox, row, col)
        return checkbox

    def create_general_settings(self):
        group_box, grid = self.create_group_box('general_settings_title')
        grid.addWidget(self.create_labeled_entry('general', 'autosave_interval_ms', 'autosave_interval_ms'), 0, 0)
        return group_box

    def create_money_settings(self):
        group_box, grid = self.create_group_box('money_settings_title')
        grid.addWidget(self.create_labeled_entry('money', 'starting_money', 'starting_money'), 0, 0)
        grid.addWidget(self.create_labeled_entry('money', 'money_per_minute_amount', 'money_per_minute_amount'), 0, 1)
        grid.addWidget(self.create_labeled_entry('money', 'money_per_minute_interval_ms', 'money_per_minute_interval_ms'), 1, 0)
        grid.addWidget(self.create_labeled_entry('money', 'cool_message_interval_ms', 'cool_message_interval_ms'), 1, 1)
        return group_box
        
    def create_civilian_settings(self):
        group_box, grid = self.create_group_box('civilian_settings_title', dependent=True)
        grid.addWidget(self.create_labeled_entry('civilian', 'speeding_limit_kmh', 'speeding_limit_kmh'), 0, 0)
        grid.addWidget(self.create_labeled_entry('civilian', 'speeding_bonus_per_second', 'speeding_bonus_per_second'), 0, 1)
        grid.addWidget(self.create_labeled_entry('civilian', 'speeding_bonus_duration_ms', 'speeding_bonus_duration_ms'), 1, 0)
        grid.addWidget(self.create_labeled_entry('civilian', 'speeding_cooldown_ms', 'speeding_cooldown_ms'), 1, 1)
        grid.addWidget(self.create_labeled_entry('civilian', 'min_speed_kmh_for_zigzag', 'min_speed_kmh_for_zigzag'), 2, 0)
        grid.addWidget(self.create_labeled_entry('civilian', 'zigzag_min_turns', 'zigzag_min_turns'), 2, 1)
        grid.addWidget(self.create_labeled_entry('civilian', 'zigzag_final_bonus_amount', 'zigzag_final_bonus_amount'), 3, 0)
        grid.addWidget(self.create_labeled_entry('civilian', 'zigzag_prorated_bonus', 'zigzag_prorated_bonus'), 3, 1)
        grid.addWidget(self.create_labeled_entry('civilian', 'zigzag_bonus_duration_ms', 'zigzag_bonus_duration_ms'), 4, 0)
        grid.addWidget(self.create_labeled_entry('civilian', 'zigzag_cooldown_ms', 'zigzag_cooldown_ms'), 4, 1)
        grid.addWidget(self.create_labeled_entry('civilian', 'wanted_fail_penalty', 'wanted_fail_penalty'), 5, 0)
        return group_box

    def create_police_settings(self):
        group_box, grid = self.create_group_box('police_settings_title', dependent=True)
        grid.addWidget(self.create_labeled_entry('police', 'police_proximity_range_m', 'police_proximity_range_m'), 0, 0)
        grid.addWidget(self.create_labeled_entry('police', 'busted_range_m', 'busted_range_m'), 0, 1)
        grid.addWidget(self.create_labeled_entry('police', 'busted_stop_time_ms', 'busted_stop_time_ms'), 1, 0)
        grid.addWidget(self.create_labeled_entry('police', 'busted_speed_limit_kmh', 'busted_speed_limit_kmh'), 1, 1)
        grid.addWidget(self.create_labeled_entry('police', 'bust_bonus_amount', 'bust_bonus_amount'), 2, 0)
        grid.addWidget(self.create_labeled_entry('police', 'police_bonus_per_second', 'police_bonus_per_second'), 2, 1)
        return group_box

    def tr(self, key, default_text=None):
        return self.translations.get(self.current_lang, {}).get(key, default_text or key)

    def load_all_languages(self):
        try:
            if not os.path.isdir(LANG_DIR): return
            for filename in os.listdir(LANG_DIR):
                if filename.endswith(".json"):
                    lang_code = os.path.splitext(filename)[0]
                    with open(os.path.join(LANG_DIR, filename), 'r', encoding='utf-8') as f:
                        data = json.load(f)
                        self.translations[lang_code] = data
                        self.lang_map[data.get("lang_name", lang_code)] = lang_code
        except Exception as e:
            print(f"Error loading languages: {e}")

    def on_lang_changed(self, lang_name):
        lang_code = self.lang_map.get(lang_name, "en")
        self.change_language(lang_code)

    def change_language(self, lang_code):
        self.current_lang = lang_code
        is_rtl = lang_code in ['he', 'ar']
        
        QApplication.instance().setLayoutDirection(Qt.RightToLeft if is_rtl else Qt.LeftToRight)
        
        self.update_ui_language()

    def update_ui_language(self):
        self.setWindowTitle(self.tr("window_title"))
        self.save_button.setText(self.tr("save_button"))
        self.reset_button.setText(self.tr("reset_button"))

        for key, widget in self.widgets.items():
            text = self.tr(key.replace("label_", ""))
            if isinstance(widget, (QLabel, QCheckBox)):
                widget.setText(text)
            elif isinstance(widget, QGroupBox):
                widget.setTitle(text)
        
        self.main_layout.activate()

    def apply_feature_dependencies(self):
        try:
            is_enabled = self.widgets['features']['roleplay_enabled'].isChecked()
            for widget in self.roleplay_dependent_widgets:
                widget.setEnabled(is_enabled)
        except KeyError:
            pass

    def load_config(self):
        try:
            with open(CONFIG_FILENAME, 'r', encoding='utf-8') as f:
                self.config_data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self.config_data = {k: v.copy() for k, v in FALLBACK_DEFAULTS.items()}

        for category, fields in FALLBACK_DEFAULTS.items():
            if category not in self.config_data:
                self.config_data[category] = {}
            for key, value in fields.items():
                self.config_data[category].setdefault(key, value)
        
        self.populate_ui()

    def populate_ui(self):
        for category, fields in self.widgets.items():
            if category in self.config_data:
                for key, widget in fields.items():
                    value = self.config_data[category].get(key)
                    if value is not None:
                        if isinstance(widget, QLineEdit): widget.setText(str(value))
                        elif isinstance(widget, QCheckBox): widget.setChecked(bool(value))
        self.apply_feature_dependencies()

    def save_config(self):
        try:
            for category, fields in self.widgets.items():
                if category in self.config_data:
                    for key, widget in fields.items():
                        if isinstance(widget, QLineEdit):
                            text_value = widget.text().strip()
                            self.config_data[category][key] = int(text_value) if text_value else 0
                        elif isinstance(widget, QCheckBox):
                            self.config_data[category][key] = widget.isChecked()
            
            with open(CONFIG_FILENAME, 'w', encoding='utf-8') as f:
                json.dump(self.config_data, f, indent=4, ensure_ascii=False)

            QMessageBox.information(self, self.tr("success_save_title"), self.tr("success_save_message"))

        except Exception as e:
            QMessageBox.critical(self, self.tr("error_title"), f"{self.tr('error_invalid_input')}\n\nDetails: {e}")

    def reset_to_defaults(self):
        reply = QMessageBox.question(self, self.tr("confirm_reset_title"), self.tr("confirm_reset_message"),
                                       QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
        if reply == QMessageBox.Yes:
            self.config_data = {k: v.copy() for k, v in FALLBACK_DEFAULTS.items()}
            self.populate_ui()


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec())
