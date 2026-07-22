@tool
extends EditorScript


func _run() -> void:
	var img := load("res://sweet-and-sour-20-32x.png")
	var palette := make_palette_from_image(img)
	palette.take_over_path("res://main_color_palette.tres")
	ResourceSaver.save(palette)

func make_palette_from_image(image: Image) -> ColorPalette:
	var colors := PackedColorArray()

	var x: int = 0
	while true:
		var color_center_x := x + image.get_height() / 2
		if color_center_x >= image.get_width(): break
		colors.push_back(image.get_pixel(color_center_x, image.get_height() / 2))
		x += image.get_height()

	print(colors.size())

	var palette := ColorPalette.new()
	palette.colors = colors
	return palette
