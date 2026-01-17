#!/bin/bash
# Convert PNG/JPG images to WebP, preserving originals

MEDIA_DIR="media/images"
ORIGINAL_DIR="media/images-original"
QUALITY=85

# Create original backup directory
mkdir -p "$ORIGINAL_DIR"

# Find and convert images
find "$MEDIA_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) | while read -r file; do
    # Get relative path from media/images
    rel_path="${file#$MEDIA_DIR/}"
    dir_path=$(dirname "$rel_path")
    base_name=$(basename "$file")
    name_no_ext="${base_name%.*}"

    # Create directory structure in originals
    mkdir -p "$ORIGINAL_DIR/$dir_path"

    # Move original
    mv "$file" "$ORIGINAL_DIR/$rel_path"

    # Convert to WebP
    cwebp -q $QUALITY "$ORIGINAL_DIR/$rel_path" -o "$MEDIA_DIR/$dir_path/$name_no_ext.webp" 2>/dev/null

    echo "Converted: $rel_path -> $dir_path/$name_no_ext.webp"
done

echo ""
echo "Done! Originals are in $ORIGINAL_DIR"
echo ""
echo "Size comparison:"
echo "  Originals: $(du -sh $ORIGINAL_DIR | cut -f1)"
echo "  WebP:      $(du -sh $MEDIA_DIR | cut -f1)"
