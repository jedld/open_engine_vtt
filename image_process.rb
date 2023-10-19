require 'mini_magick'
require 'image_optim'

public_folder_path = 'public/actions'  # Assuming your script is at the root of your Sinatra app.
image_extensions = %w[.jpg .jpeg .png .gif]

# Create an ImageOptim instance for optimization
image_optim = ImageOptim.new(:advpng => false, :pngout => false, :oxipng => false, :jhead => false, :svgo => false)  # disable pngout if you don't have it installed

# Iterate through the public directory to find image files
Dir.foreach(public_folder_path) do |filename|
  next unless image_extensions.include?(File.extname(filename).downcase)

  # Construct the full path
  filepath = File.join(public_folder_path, filename)

  # Resize using MiniMagick
  image = MiniMagick::Image.open(filepath)
  image.resize "128x128"  # Change this to your desired resolution

  # Save the resized image
  image.write(filepath)

  # Optimize the resized image
  image_optim.optimize_image!(filepath)
end

puts "Images processed successfully!"
