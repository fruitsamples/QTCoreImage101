/*

File: MyOpenGLView.m of QTCoreImage101

Author: QuickTime DTS

Change History (most recent first): <3> 10/08/09 minor update
                                    <2> 06/14/05 call QTVisualContextTask while owning lock
                                                 overide and add lock around update
                                    <1> 05/29/05 initial release

� Copyright 2005 Apple Computer, Inc. All rights reserved.

IMPORTANT:  This Apple software is supplied to you by Apple Computer, Inc. ("Apple") in
consideration of your agreement to the following terms, and your use, installation,
modification or redistribution of this Apple software constitutes acceptance of these
terms.  If you do not agree with these terms, please do not use, install, modify or
redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and subject to these
terms, Apple grants you a personal, non-exclusive license, under Apple's copyrights in
this original Apple software (the "Apple Software"), to use, reproduce, modify and
redistribute the Apple Software, with or without modifications, in source and/or binary
forms; provided that if you redistribute the Apple Software in its entirety and without
modifications, you must retain this notice and the following text and disclaimers in all
such redistributions of the Apple Software. Neither the name, trademarks, service marks
or logos of Apple Computer, Inc. may be used to endorse or promote products derived from
the Apple Software without specific prior written permission from Apple.  Except as
expressly stated in this notice, no other rights or licenses, express or implied, are
granted by Apple herein, including but not limited to any patent rights that may be
infringed by your derivative works or by other works in which the Apple Software may be
incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES NO WARRANTIES,
EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF
NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE
APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE
USE, REPRODUCTION, MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER
CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT
LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/

#import "MyOpenGLView.h"

#pragma mark Render Callback
// this is the CoreVideo DisplayLink callback notifying the application when the display will need each frame
// and is called when the DisplayLink is running -- in response, we call our getFrameForTime method
static CVReturn MyRenderCallback(CVDisplayLinkRef displayLink, 
								 const CVTimeStamp *inNow, 
								 const CVTimeStamp *inOutputTime, 
								 CVOptionFlags flagsIn, 
								 CVOptionFlags *flagsOut, 
                                 void *displayLinkContext)
{
	return [(MyOpenGLView *)displayLinkContext getFrameForTime:inOutputTime flagsOut:flagsOut];
}

#pragma mark
@implementation MyOpenGLView

// initialize
-(void)awakeFromNib
{
	movie = nil;
    displayLink = NULL;
	textureContext = NULL;
    currentFrame = NULL;
    pointillizeFilter = nil;
    edgeWorkFilter = nil;
    ciContext = nil;
    
    // we need a lock around our draw function so two different
    // threads don't try and draw at the same time
    lock = [NSRecursiveLock new];
    
    effectFilter = nil;
    effectValue = 1.0;
}

// destruction
- (void)dealloc
{
	// make sure the cleanUp routine is
    // called first before going away
	[self cleanUp];    
    [super dealloc];
}

// it is very important that we clean up the rendering
// objects before the view is disposed, remember that with the
// display link running you're applications render callback may be
// called at any time including when the application is quitting or the
// view is being disposed, additionally you need to make sure you're not
// consuming OpenGL resources or leaking textures -- this clean up routine
// makes sure to stop and release everything
-(void)cleanUp
{
	// stop and release the movie
    if (movie){
    	[movie setRate:0.0];
        SetMovieVisualContext([movie quickTimeMovie], NULL);
        [movie release];
        movie = nil;
    }
    
    // it is critical to dispose of the display link
    if (displayLink) {
    	CVDisplayLinkStop(displayLink);
        CVDisplayLinkRelease(displayLink);
        displayLink = NULL;
    }
    
    // don't leak textures
    if (currentFrame) {
    	CVOpenGLTextureRelease(currentFrame);
        currentFrame = NULL;
    }

	// release the OpenGL Texture Context
    if (textureContext) {
    	 CFRelease(textureContext);
         textureContext = NULL;
    }
    
    // release the Core Image Filters
    if (pointillizeFilter) {
    	[pointillizeFilter release];
        pointillizeFilter = nil;
    }
    
    if (edgeWorkFilter) {
    	[edgeWorkFilter release];
        edgeWorkFilter = nil;
    }
    
    // release the Core Image Context
    if (ciContext) {
    	[ciContext release];
        ciContext = nil;
    }
    
    if (lock) {
    	[lock release];
        lock = nil;
    }
}

// do our setup -- this is a good place to create the display link and filters because
// we're called only once and after the OpenGL context is created and the drawable is attached
- (void)prepareOpenGL
{
	GLint swapInterval = 1;
    
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);   // black background
   
   	// set up the GL contexts swap interval -- passing 1 means that
    // the buffers are swapped only during the vertical retrace of the monitor
	[[self openGLContext] setValues:&swapInterval forParameter:NSOpenGLCPSwapInterval];
    
    // create a Core Image Context -- in Core Image, images are evaluated to a Core Image context
    // which represents a drawing destination. Core Image contexts are created per window rather than
    // one per view and can be created from an OpenGL graphics context
    
 	// create CGColorSpaceRef needed for the contextWithCGLContext method
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        
    // create CIContext -- the CIContext object provides an evaluation context for
    // rendering a Core Image image (CIImage) through Quartz 2D or OpenGL
    ciContext = [[CIContext contextWithCGLContext:CGLContextObj([[self openGLContext] CGLContextObj])	// Core Image draws all output into the surface attached to this OpenGL context
            	pixelFormat:CGLPixelFormatObj([[self pixelFormat] CGLPixelFormatObj])					// must be the same pixel format used to create the cgl context
                options:[NSDictionary dictionaryWithObjectsAndKeys:(id)colorSpace, kCIContextOutputColorSpace,	 // dictionary containing color space information
                                                                   (id)colorSpace, kCIContextWorkingColorSpace, nil]] retain];
    // release the colorspace we don't need it anymore
    CGColorSpaceRelease(colorSpace);

    // create CIFilters 
    pointillizeFilter = [[CIFilter filterWithName:@"CIPointillize"] retain];	// pointillize filter	
    [pointillizeFilter setDefaults];						    				// set the filter to its default values
    edgeWorkFilter = [[CIFilter filterWithName:@"CIEdgeWork"] retain];	// edgework filter	
    [edgeWorkFilter setDefaults];										// set the filter to its default values
   
    // create display link for the main display
    CVDisplayLinkCreateWithCGDisplay(kCGDirectMainDisplay, &displayLink);
    if (NULL != displayLink) {
    	// set the current display of a display link
    	CVDisplayLinkSetCurrentCGDisplay(displayLink, kCGDirectMainDisplay);
        
        // set the renderer output callback function
    	CVDisplayLinkSetOutputCallback(displayLink, &MyRenderCallback, self);
        
        // we don't activate the display link yet
    }
    
	// creates a new OpenGL texture context for a specified OpenGL context and pixel format
	QTOpenGLTextureContextCreate(kCFAllocatorDefault,										// an allocator to Create functions
    							 CGLContextObj([[self openGLContext] CGLContextObj]),		// the OpenGL context
                                 CGLPixelFormatObj([[self pixelFormat] CGLPixelFormatObj]), // pixelformat object that specifies buffer types and other attributes of the context
                                 NULL,														// a CF Dictionary of attributes
                                 &textureContext);											// returned OpenGL texture context

	// initally we use the pointillize effect
	effectFilter = pointillizeFilter;
}

// good practice to lock around update
- (void)update
{
    [lock lock];
    	[super update];
    [lock unlock];
}

//  adjust the viewport
- (void)reshape
{ 
	GLfloat minX, minY, maxX, maxY;
    
    NSRect sceneBounds = [self bounds];
 	NSRect frame = [self frame];
	
    minX = NSMinX(sceneBounds);
	minY = NSMinY(sceneBounds);
	maxX = NSMaxX(sceneBounds);
	maxY = NSMaxY(sceneBounds);
    
    // for best results when using Core Image to render into an OpenGL context follow these guidelines:
    // * ensure that the a single unit in the coordinate space of the OpenGL context represents a single pixel in the output device
    // * the Core Image coordinate space has the origin in the bottom left corner of the screen -- you should configure the OpenGL
    //   context in the same way
    // * the OpenGL context blending state is respected by Core Image -- if the image you want to render contains translucent pixels,
    //   it�s best to enable blending using a blend function with the parameters GL_ONE, GL_ONE_MINUS_SRC_ALPHA

    // some typical initialization code for a view with width W and height H
    
    glViewport(0, 0, GLsizei(frame.size.width), GLsizei(frame.size.height));	// set the viewport
    
    glMatrixMode(GL_MODELVIEW);    // select the modelview matrix
    glLoadIdentity();              // reset it
    
    glMatrixMode(GL_PROJECTION);   // select the projection matrix
    glLoadIdentity();              // reset it
    
    gluOrtho2D(minX, maxX, minY, maxY);	// define a 2-D orthographic projection matrix
    
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_BLEND);
}

// draw
- (void)drawRect:(NSRect)rect
{ 
    [lock lock];	// prevent drawing from another thread if we're drawing already
    
    	// make the GL context the current context
        [[self openGLContext] makeCurrentContext];
        
        // clear to black if nothing else
        glClear(GL_COLOR_BUFFER_BIT);
        
        if (NULL != currentFrame) {
        	// we have a frame so draw something
            NSRect frame = [self frame];
            
			CGRect	imageRect;
			CIImage	*inputImage;
		
            // creates a Core Image image from the contents of a CVImageBuffer or its subclasses
            // in our case an OpenGL texture-based image buffer of type CVOpenGLTextureRef
			inputImage = [CIImage imageWithCVImageBuffer:currentFrame];

			// make sure to get the image extent before applying any filters -- it is the
            // rectangle that specifies the x-value of the rectangle origin, the y-value of
            // the rectangle origin, and the width and height in working space coordinates
            imageRect = [inputImage extent];
	
    		// set the input image and parameter for the effect we're rendering with
            [effectFilter setValue:inputImage forKey:@"inputImage"];
            [effectFilter setValue:[NSNumber numberWithFloat:effectValue] forKey:@"inputRadius"];
			
            // render our resulting image into our context
			[ciContext drawImage: [effectFilter valueForKey:@"outputImage"] 
                       atPoint: CGPointMake((int)((frame.size.width - imageRect.size.width) * 0.5),
                                            (int)((frame.size.height - imageRect.size.height) * 0.5)) // use integer coordinates to avoid interpolation
			           fromRect:imageRect];
        }
        
        glFlush();
                
        // give time to the Visual Context so it can release internally held resources for later re-use
        // this function should be called in every rendering pass, after old images have been released, new
        // images have been used and all rendering has been flushed to the screen.
        QTVisualContextTask(textureContext);
        
	[lock unlock];
}

#pragma mark Display Link
// getFrameForTime is called from the Display Link callback when it's time for us to check to see
// if we have a frame available to render -- if we do, draw -- if not, just task the Visual Context and split
- (CVReturn)getFrameForTime:(const CVTimeStamp*)timeStamp flagsOut:(CVOptionFlags*)flagsOut
{
	// there is no autorelease pool when this method is called because it will be called from another thread
    // it's important to create one or you will leak objects
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	
	// check for new frame
	if (NULL != textureContext && QTVisualContextIsNewImageAvailable(textureContext, timeStamp)) {
    	
        // if we have a previous frame release it
		if (NULL != currentFrame) {
        	CVOpenGLTextureRelease(currentFrame);
        	currentFrame = NULL;
        }
        
        // get a "frame" (image buffer) from the Visual Context, indexed by the provided time
		OSStatus status = QTVisualContextCopyImageForTime(textureContext, NULL, timeStamp, &currentFrame);
		
        // the above call may produce a null frame so check for this first
        // if we have a frame, then draw it
		if ((noErr == status) && (NULL != currentFrame)) {
        	[self drawRect:NSZeroRect];
		}
	}
    
    [pool release];

	return kCVReturnSuccess;
}

#pragma mark Movie
// open a Movie File and instantiate a QTMovie object
-(void)openMovie:(NSString*)path
{
	if (textureContext != nil) {
        
        // if we already have a QTMovie release it
        if (nil != movie) [movie release];
        
        movie = [[QTMovie alloc] initWithFile:path error:nil];
        
        // set Movie to loop
        [movie setAttribute:[NSNumber numberWithBool:YES] forKey:QTMovieLoopsAttribute];
        
        // targets a Movie to render into a visual context
        SetMovieVisualContext([movie quickTimeMovie], textureContext);
        
        // play the Movie
        [movie setRate:1.0];

		// set the window title from the Movie if it has a name associated with it
        [[self window] setTitle:[movie attributeForKey:QTMovieDisplayNameAttribute]];
    }
}

#pragma mark Accessors
// return the display link ref
-(CVDisplayLinkRef)displayLink;
{
	return displayLink;
}

// both of these are hooked up via bindings

// set the effect parameter value
-(IBAction)setEffectValue:(id)sender
{
    effectValue = [sender floatValue];
}

// set which effect we're going to use to render
-(IBAction)setEffect:(id)sender
{
	if ([sender intValue]) {
    	effectFilter = edgeWorkFilter;
    } else {
    	effectFilter = pointillizeFilter;
    }
}

@end
