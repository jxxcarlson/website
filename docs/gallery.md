# A Scripta Gallery Block

## Specification

 Consider the draft scripta block below:                                                                                                                                                                   
                         
```                                                                                                                                                                                                            
  | gallery height:300 title:The Earth                                                                                                                                                                      
  earth/great-salt-lake-utah-nasa.webp, Great Salt Lake                                                                                                                                                     
  earth/glacier.webp, Glacier 
```                                                                                                                                                                              
                                                                                                                                                                                                            
I would like you to implement this block.  
The idea is render a sequence of images                                                                                                                        
in "gallery-format." Each image is to be displayed with height 300 px. Above the image                                                                                                                    
currently diplayed is the title.  Below is the current image. Below the current image                                                                                                                     
is a row of controls.  Reading from left to right: prev-button, the caption of the image, (j+1/N), next-button                                                                                            
                                                                                                                                                                                                        
The prev-button is a left-pointing solid triangle. Clicking it changes the display to the previous image.                                                                                                 
The next-button is a right-pointing solid triangle. Clicking it changes the display to the next image.                                                                                                    
                                                                                                                                                                                                        
The images are defined by the body of the gallery block. Think of it as a circular list. In the case at                                                                                                   
hand the it is a list with N = 2. Each item in the has an index j in the range 0 to N - 1.  Each item                                                                                                     
defines a pair (image-path, caption).                                                                                                                                                                     
                                                                                                                                                                                                            
Do you understand?  Please ask if there is something which is not clear.  

## Implementation

Done! The gallery block is implemented.   *(Brewed for 1m 55s)*                                                                                                                                                                
         
```                                                                                                                                                                                                            
  Syntax:                                                                                                                                                                                                   
  | gallery height:300 title:The Earth                                                                                                                                                                      
  earth/great-salt-lake-utah-nasa.webp, Great Salt Lake                                                                                                                                                     
  earth/glacier.webp, Glacier  
```                                                                                                                                                                             
                                                                                                                                                                                                            
Layout:                                                                                                                                                                                                   
- Title at top (optional, from title: property)                                                                                                                                                           
- Image (height from height: property, default 300px)                                                                                                                                                     
- Controls: ◀ | caption | (1/2) | ▶                                                                                                                                                                       
                                                                                                                                                                                                        
Features:                                                                                                                                                                                                 
- Circular navigation (wraps from last to first and vice versa)                                                                                                                                           
- 1-indexed counter display                                                                                                                                                                               
- Images from /media/images/ path                                                                                                                                                                         
- Comma-separated format: path, caption  
