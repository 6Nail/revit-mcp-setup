# -*- coding: utf-8 -*-
"""Коробка из красного кирпича: 4 стены, 10 x 10 м (по наружным граням), высота 5 м, толщина 5 см.

Как запустить:
  1. Кнопка pyRevit (папка BrickBox.extension) - откройте проект и нажмите "BrickBox".
  2. Через Claude + MCP: инструмент execute_revit_code, передать содержимое этого файла.
  3. pyRevit Python Shell: вставить код и выполнить.

Нужен открытый ПРОЕКТ Revit (не семейство). Работает в Revit 2024-2027 (pyRevit 7).
Всё создаётся одной транзакцией: отменяется одним Ctrl+Z.
"""
from pyrevit import revit, DB, forms
from System.Collections.Generic import List

# ----------------------------- Параметры -----------------------------
SIDE_M = 10.0                 # наружный размер коробки в плане, метры
HEIGHT_M = 5.0                # высота стен, метры
THICKNESS_M = 0.05            # толщина стен, метры (5 см)
ORIGIN_X_M = 0.0              # положение угла коробки (X, метры)
ORIGIN_Y_M = 0.0              # положение угла коробки (Y, метры)
MATERIAL_NAME = u"Кирпич красный"
WALL_TYPE_NAME = u"Кирпич красный 50 мм"
BRICK_COLOR = (156, 60, 45)   # RGB красного кирпича
# ---------------------------------------------------------------------

M_TO_FT = 1.0 / 0.3048        # внутренние единицы Revit - футы


def ft(meters):
    return meters * M_TO_FT


def find_by_name(doc, cls, name):
    for el in DB.FilteredElementCollector(doc).OfClass(cls):
        if el.Name == name:
            return el
    return None


def get_or_create_material(doc):
    """Материал 'Кирпич красный': красный цвет, штриховка по возможности из шаблона."""
    mat = find_by_name(doc, DB.Material, MATERIAL_NAME)
    if mat is None:
        mat_id = DB.Material.Create(doc, MATERIAL_NAME)
        mat = doc.GetElement(mat_id)
    mat.Color = DB.Color(*BRICK_COLOR)
    try:
        mat.MaterialClass = u"Masonry"
    except Exception:
        pass
    # Внешний вид (для рендера): берём любой кирпичный ресурс из проекта, если он есть
    try:
        for asset in DB.FilteredElementCollector(doc).OfClass(DB.AppearanceAssetElement):
            nm = asset.Name.lower()
            if "brick" in nm or u"кирпич" in nm:
                mat.AppearanceAssetId = asset.Id
                break
    except Exception:
        pass
    return mat


def get_or_create_wall_type(doc, material):
    """Тип стены с одним слоем 5 см из красного кирпича (копия базового типа стены)."""
    existing = find_by_name(doc, DB.WallType, WALL_TYPE_NAME)
    if existing is not None:
        return existing

    base = None
    for wt in DB.FilteredElementCollector(doc).OfClass(DB.WallType):
        if wt.Kind == DB.WallKind.Basic:
            base = wt
            break
    if base is None:
        raise Exception(u"В проекте нет базового типа стены, который можно скопировать.")

    new_type = base.Duplicate(WALL_TYPE_NAME)
    layer = DB.CompoundStructureLayer(ft(THICKNESS_M), DB.MaterialFunctionAssignment.Structure, material.Id)
    layers = List[DB.CompoundStructureLayer]()
    layers.Add(layer)
    # новая простая структура из одного слоя: не зависит от слоёв копируемого типа
    new_type.SetCompoundStructure(DB.CompoundStructure.CreateSimpleCompoundStructure(layers))
    return new_type


def get_base_level(doc):
    """Самый нижний уровень проекта; если уровней нет - создаём 'Уровень 0'."""
    levels = list(DB.FilteredElementCollector(doc).OfClass(DB.Level))
    if levels:
        return sorted(levels, key=lambda l: l.Elevation)[0]
    level = DB.Level.Create(doc, 0.0)
    level.Name = u"Уровень 0"
    return level


def build_box(doc, wall_type, level):
    """4 стены по осевому прямоугольнику так, чтобы НАРУЖНЫЕ грани давали SIDE_M x SIDE_M."""
    half_t = THICKNESS_M / 2.0
    x0 = ORIGIN_X_M + half_t
    y0 = ORIGIN_Y_M + half_t
    x1 = ORIGIN_X_M + SIDE_M - half_t
    y1 = ORIGIN_Y_M + SIDE_M - half_t
    corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    height = ft(HEIGHT_M)
    walls = []
    for i in range(4):
        ax, ay = corners[i]
        bx, by = corners[(i + 1) % 4]
        line = DB.Line.CreateBound(DB.XYZ(ft(ax), ft(ay), level.Elevation), DB.XYZ(ft(bx), ft(by), level.Elevation))
        wall = DB.Wall.Create(doc, line, wall_type.Id, level.Id, height, 0.0, False, False)
        walls.append(wall)
    return walls


def main():
    doc = revit.doc
    if doc is None or doc.IsFamilyDocument:
        forms.alert(u"Откройте проект Revit (не семейство) и запустите скрипт снова.", exitscript=True)

    with revit.Transaction(u"Коробка из красного кирпича 10x10x5 м"):
        material = get_or_create_material(doc)
        wall_type = get_or_create_wall_type(doc, material)
        level = get_base_level(doc)
        walls = build_box(doc, wall_type, level)

    print(u"Создано стен: {}".format(len(walls)))
    print(u"Размер по наружным граням: {} x {} м, высота {} м, толщина {} см".format(
        SIDE_M, SIDE_M, HEIGHT_M, int(round(THICKNESS_M * 100))))
    print(u"Материал: {}; тип стены: {}; уровень: {}".format(MATERIAL_NAME, WALL_TYPE_NAME, level.Name))


main()
