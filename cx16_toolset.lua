-- Constants
local COLOR_DEPTH_1BPP = 2
local COLOR_DEPTH_2BPP = 4
local COLOR_DEPTH_4BPP = 16
local COLOR_DEPTH_8BPP = 256

local color_depth_map = {
    ["1bpp"] = COLOR_DEPTH_1BPP,
    ["2bpp"] = COLOR_DEPTH_2BPP,
    ["4bpp"] = COLOR_DEPTH_4BPP,
    ["8bpp"] = COLOR_DEPTH_8BPP
}

local tile_size_map = {
    ["8x8"] = { 8, 8 },
    ["16x16"] = { 16, 16 },
    ["8x16"] = { 8, 16 },
    ["16x8"] = { 16, 8 }
}

-- Business Logic Functions

local function export_tileset(sprite, tile_size, color_depth)
    local exported_data = {}
    local tiles_per_row = sprite.width / tile_size[1]
    local tiles_per_column = sprite.height / tile_size[2]
    local cel = sprite.cels[1]
    local image = cel.image
    local cel_x, cel_y = cel.bounds.x, cel.bounds.y
    local bits_per_pixel = math.log(color_depth, 2)

    for y = 0, tiles_per_column - 1 do
        for x = 0, tiles_per_row - 1 do
            local tile_data = {}
            for ty = 0, tile_size[2] - 1 do
                local byte, bits_filled = 0, 0
                for tx = 0, tile_size[1] - 1 do
                    local pixel_x, pixel_y = x * tile_size[1] + tx, y * tile_size[2] + ty
                    local pixel_value = 0

                    if pixel_x >= cel_x and pixel_x < cel_x + cel.bounds.width and
                        pixel_y >= cel_y and pixel_y < cel_y + cel.bounds.height then
                        local cel_pixel_x, cel_pixel_y = pixel_x - cel_x, pixel_y - cel_y
                        pixel_value = image:getPixel(cel_pixel_x, cel_pixel_y) % color_depth
                    end

                    byte = (byte << bits_per_pixel) | pixel_value
                    bits_filled = bits_filled + bits_per_pixel

                    if bits_filled >= 8 or tx == tile_size[1] - 1 then
                        table.insert(tile_data, byte)
                        byte, bits_filled = 0, bits_filled % 8
                    end
                end
            end
            table.insert(exported_data, tile_data)
        end
    end
    return exported_data
end

local function validate_sprite(sprite, tile_size, color_depth)
    if #sprite.layers ~= 1 or #sprite.cels ~= 1 then
        return false, "Sprite must have only one layer and one cel."
    end
    if sprite.colorMode ~= ColorMode.INDEXED then
        return false, "Sprite must be in INDEXED color mode."
    end
    if sprite.width % tile_size[1] ~= 0 or sprite.height % tile_size[2] ~= 0 then
        return false, "Sprite dimensions must be divisible by the tile size."
    end
    local image = sprite.cels[1].image
    for x = 0, image.width - 1 do
        for y = 0, image.height - 1 do
            if image:getPixel(x, y) >= color_depth then
                return false, "Color count exceeds the selected color depth."
            end
        end
    end
    return true
end

local function save_binary_file(filename, data)
    local file, err = io.open(filename, "wb")
    if not file then error("Failed to open file: " .. err) end
    for _, tile in ipairs(data) do
        for _, byte in ipairs(tile) do
            file:write(string.char(byte))
        end
    end
    file:close()
end

local function export_palette(palette_filename, sprite, color_depth)
    local palette = sprite.palettes[1]
    local ncolors = math.min(color_depth, #palette)

    local file, err = io.open(palette_filename, "wb")
    if not file then error("Failed to open palette file: " .. err) end

    for i = 0, ncolors - 1 do
        local color = palette:getColor(i)
        local red = math.floor(color.red * 15 / 255)
        local green = math.floor(color.green * 15 / 255)
        local blue = math.floor(color.blue * 15 / 255)
        file:write(string.char((green << 4) | blue))
        file:write(string.char(red))
    end
    file:close()
end

local function make_palette_cx16_compatible(sprite)
    local palette = sprite.palettes[1]

    for i = 0, #palette - 1 do
        local color = palette:getColor(i)
        local red = math.floor(color.red * 15 / 255)     -- Scale to 4 bits
        local green = math.floor(color.green * 15 / 255) -- Scale to 4 bits
        local blue = math.floor(color.blue * 15 / 255)   -- Scale to 4 bits

        -- Update the color in place
        palette:setColor(i, Color { r = red * 17, g = green * 17, b = blue * 17 })
    end

    app.alert("Palette has been updated to Commander X16 compatible format.")
end

local function detect_duplicate_colors(sprite)
    local palette = sprite.palettes[1]
    if not palette then
        error("No palette found.")
    end

    local duplicates = {}
    local processed = {} -- Track already processed indices

    for i = 0, #palette - 1 do
        if not processed[i] then
            local color1 = palette:getColor(i)
            for j = i + 1, #palette - 1 do
                local color2 = palette:getColor(j)
                if color1.red == color2.red and color1.green == color2.green and color1.blue == color2.blue then
                    if not duplicates[i] then duplicates[i] = {} end
                    table.insert(duplicates[i], j)
                    processed[j] = true -- Mark duplicate index as processed
                end
            end
        end
    end

    return duplicates
end

local function reassign_palette_indexes(sprite, duplicates)
    local cel = sprite.cels[1]
    local image = cel.image

    -- Create a remap table to reassign duplicate indices
    local remap = {}
    for index, dupes in pairs(duplicates) do
        for _, duplicate_index in ipairs(dupes) do
            remap[duplicate_index] = index
        end
    end

    -- Iterate over all pixels in the image and reassign palette indexes
    for y = 0, image.height - 1 do
        for x = 0, image.width - 1 do
            local pixel_index = image:getPixel(x, y)
            local new_index = remap[pixel_index] or pixel_index
            if new_index ~= pixel_index then
                image:drawPixel(x, y, new_index)
            end
        end
    end

    app.alert("Palette indexes have been reassigned to remove duplicates.")
end

local function compact_palette(sprite)
    local cel = sprite.cels[1]
    local image = cel.image
    local palette = sprite.palettes[1]

    local used_indices = {}

    -- Track which palette indexes are used
    for y = 0, image.height - 1 do
        for x = 0, image.width - 1 do
            local pixel_index = image:getPixel(x, y)
            used_indices[pixel_index] = true
        end
    end

    -- Map used indices to a new compact set starting from 0
    local new_index_map = {}
    local next_free_index = 0
    for i = 0, #palette - 1 do
        if used_indices[i] then
            new_index_map[i] = next_free_index
            next_free_index = next_free_index + 1
        end
    end

    -- Reassign all pixels in the image to their new compact indices
    for y = 0, image.height - 1 do
        for x = 0, image.width - 1 do
            local old_index = image:getPixel(x, y)
            local new_index = new_index_map[old_index]
            if new_index then
                image:drawPixel(x, y, new_index)
            end
        end
    end

    -- Create a new palette with only the used colors
    local new_palette = Palette(next_free_index)
    for old_index, new_index in pairs(new_index_map) do
        new_palette:setColor(new_index, palette:getColor(old_index))
    end

    sprite:setPalette(new_palette)

    app.alert("Palette has been compacted and unused colors removed.")
end


-- GUI

local dlg = Dialog { title = "Export tileset to Commander X16 format" }

dlg:tab { id = "image_converter",
    text = "Image converter",
    onclick = function()

    end }

dlg:newrow { always = true }
dlg:label { id = "converter_help_1",
    text = "Needs indexed mode sprite!" }
dlg:label { id = "converter_help_2",
    text = "Go to: Sprite->Color mode->Indexed" }
dlg:label { id = "converter_help_3",
    text = "This button will convert palette to CX16 format" }
dlg:label { id = "converter_help_4",
    text = "It will also remove duplicate colors and compress palette" }
dlg:newrow { always = false }

dlg:button {
    id = "convert_palette_cx16",
    text = "Convert to CX16 colors",
    onclick = function()
        local sprite = app.sprite
        local color_depth = color_depth_map[dlg.data.colorDepth]
        make_palette_cx16_compatible(sprite)
        local duplicates = detect_duplicate_colors(sprite)
        reassign_palette_indexes(sprite, duplicates)
        compact_palette(sprite)
        dlg:close()
    end
}

dlg:tab { id = "image_exporter",
    text = "Image exporter",
    onclick = function()

    end }

dlg:combobox {
    id = "tileSize",
    label = "Tile size",
    option = "8x8",
    options = { "8x8", "16x16", "8x16", "16x8" }
}

dlg:combobox {
    id = "colorDepth",
    label = "Color depth",
    option = "1bpp",
    options = { "1bpp", "2bpp", "4bpp", "8bpp" }
}

dlg:button {
    id = "export_palette",
    text = "Export palette",
    onclick = function()
        local sprite = app.sprite
        local color_depth = color_depth_map[dlg.data.colorDepth]
        local palette_filename = app.fs.filePathAndTitle(sprite.filename) .. ".pal"
        export_palette(palette_filename, sprite, color_depth)
        app.alert("Palette exported successfully to " .. palette_filename)
    end
}

dlg:button {
    id = "export",
    text = "Export",
    onclick = function()
        local sprite = app.sprite
        local tile_size = tile_size_map[dlg.data.tileSize]
        local color_depth = color_depth_map[dlg.data.colorDepth]
        local valid, error_message = validate_sprite(sprite, tile_size, color_depth)
        if not valid then
            app.alert(error_message)
            return
        end
        local tileset = export_tileset(sprite, tile_size, color_depth)
        local filename = app.fs.filePathAndTitle(sprite.filename) .. ".cx16.bin"
        save_binary_file(filename, tileset)
        app.alert("Tileset exported successfully to " .. filename)
        dlg:close()
    end
}
dlg:newrow()

dlg:endtabs { id = string,
    selected = "wut",
    align = Align.center,
    onchange = function()

    end }

dlg:button { id = "exit", text = "Exit", onclick = function() dlg:close() end }
dlg:show { wait = false }
