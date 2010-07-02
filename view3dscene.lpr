{
  Copyright 2002-2010 Michalis Kamburelis.

  This file is part of "view3dscene".

  "view3dscene" is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  "view3dscene" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with "view3dscene"; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

  ----------------------------------------------------------------------------
}

{ WWW page of this program, with user documentation,
  is here: [http://vrmlengine.sourceforge.net/view3dscene.php].

  Note: if you want to find out how to use Kambi VRML game engine
  in your own programs, this program's source code is not the best place
  to study. It's quite complex, using virtually every feature of our engine,
  making it all configurable from menu, and filled with a lot
  of user interface details.
  Instead you should look at simple example programs in
  ../kambi_vrml_game_engine/examples/vrml/simplest_vrml_browser.lpr,
  ../kambi_vrml_game_engine/examples/vrml/scene_manager_demos.lpr

  Also ../kambi_vrml_game_engine/examples/vrml/many2vrml.lpr is
  an example how to write simple command-line converter from Collada, OBJ, 3DS
  (and all other model formats we can read) to VRML.

  This is a VRML/X3D browser, also able to load many other 3D model formats.
  Basic components are :
  - use LoadVRMLSequence to load any format to VRML scene.
    This converts any known (to our engine) 3D model format to VRML.
    This convertion doesn't lose anything because VRML is able to
    express everything that is implemented in other 3D formats readers.
    And we gain the simplicity of this program (we just treat everything
    as VRML scene, actually VRML animation),
    optimization (display lists optimizations,
    OpenGL renderer cache inside VRML renderer), functionality
    (like automatic normals generation based on creaseAngle).
  - render scene using TVRMLGLScene (actually TVRMLGLAnimation
    and TVRMLGLScene is inside)
  - use Cameras and TGLUIWindow to let user navigate
    over the scene using various navigation modes
    (Examine, Walk) and with optional gravity
  - build TVRMLTriangleOctree to allow collision detection for
    Walk camera and to allow raytracer
  - build TVRMLShapeOctree to allow frustum culling using
    octree by TVRMLGLScene
  - use VRMLRayTracer embedded in RaytraceToWindow module to allow
    viewing raytraced image
  - allow some kind of object picking with mouse left button
    (for VRML sensors) and right button (to select for editing).
    This uses simple one-primary-ray casting.
}

program view3dscene;

{$ifdef MSWINDOWS}
  {$R windows/view3dscene.res}
{$endif MSWINDOWS}

uses KambiUtils, SysUtils, VectorMath, Boxes3D, Classes, KambiClassUtils,
  BFNT_BitstreamVeraSansMono_Bold_m15_Unit,
  ParseParametersUnit, ProgressUnit, Cameras,
  KambiStringUtils, KambiFilesUtils, KambiTimeUtils,
  DataErrors, KambiLog, ProgressConsole, DateUtils, Frustum,
  Images, CubeMap, DDS, Base3D,
  { OpenGL related units: }
  GL, GLU, GLExt, GLWindow, KambiGLUtils, OpenGLBmpFonts,
  GLWinMessages, ProgressGL, GLWindowRecentFiles, GLImages,
  GLAntiAliasing, GLVersionUnit, GLCubeMap,
  { VRML (and possibly OpenGL) related units: }
  VRMLFields, VRMLShapeOctree,
  VRMLNodes, Object3DAsVRML, VRMLGLScene, VRMLTriangle,
  VRMLScene, VRMLNodesDetailOptions,
  VRMLCameraUtils, VRMLErrors, VRMLGLHeadLight, VRMLGLAnimation,
  VRMLRendererOptimization, VRMLOpenGLRenderer, VRMLShape, RenderStateUnit,
  VRMLShadowMaps,
  { view3dscene-specific units: }
  TextureFilters, ColorModulators, V3DSceneLights, RaytraceToWindow,
  V3DSceneAllCameras, SceneChangesUnit, BGColors, V3DSceneViewpoints,
  V3DSceneConfig, V3DSceneBlending, V3DSceneWarnings, V3DSceneFillMode,
  V3DSceneAntiAliasing, V3DSceneScreenShot, V3DSceneOptimization,
  V3DSceneShadows, V3DSceneOctreeVisualize, V3DSceneMiscConfig;

var
  Glw: TGLUIWindow;

  ShowFrustum: boolean = false;
  ShowFrustumAlwaysVisible: boolean = false;

  { ponizsze zmienne istotne tylko w trybach nawigacji ktore robia
    wykrywanie kolizji:

    When SceneAnimation.Collides = true, octree is always initialized
    (we're after SceneOctreeCreate, before SceneOctreeDestroy).
    Otherwise, when SceneAnimation.Collides = false, octree *may* be available
    but doesn't have to. When setting SceneAnimation.Collides to false we do not
    immediately destroy the octree (in case user will just go back
    to SceneAnimation.Collides = true next), but it will be destroyed on next
    rebuild of octree (when we will just destroy old and not recreate new).
  }
  MenuCollisionCheck: TMenuItemChecked;

  { ustalane w Init, finalizowane w Close }
  StatusFont: TGLBitmapFont;

  RecentMenu: TGLRecentFiles;

  { These are so-called "scene global variables".
    Modified only by LoadSceneCore (and all using it Load*Scene* procedures)
    and FreeScene.
    Also note that Glw.Caption (and FPSBaseCaption) also should be modified
    only by those procedures.

    In this program's comments I often talk about "null values" of these
    variables, "null values" mean that these variables have some *defined
    but useless* values, i.e.
      SceneAnimation.Loaded = false
      SceneFileName = '' }
  { Note that only one SceneAnimation object is created and present for the whole
    lifetime of this program, i.e. when I load new scene (from "Open"
    menu item) I DO NOT free and create new SceneAnimation object.
    Instead I'm only freeing and creating underlying scenes
    (by Close / Load of TVRMLGLAnimation).
    This way I'm preserving values of all Attributes.Xxx when opening new scene
    from "Open" menu item. }
  SceneAnimation: TVRMLGLAnimation;
  SceneFilename: string;
  SceneHeadlight: TVRMLGLHeadlight;

  SelectedItem: PVRMLTriangle;
  { SelectedPoint* always lies on SelectedItem item,
    and it's meaningless when SelectedItem = nil.
    World is in world coords,
    local in local shape (SelectedItem^.State.Transform) coords. }
  SelectedPointWorld, SelectedPointLocal: TVector3Single;
  MenuSelectedOctreeStat: TMenuItem;
  MenuSelectedInfo: TMenuItem;
  MenuSelectedLightsInfo: TMenuItem;
  MenuRemoveSelectedGeometry: TMenuItem;
  MenuRemoveSelectedFace: TMenuItem;
  MenuEditMaterial: TMenu;
  MenuMergeCloseVertexes: TMenuItem;

  SceneWarnings: TSceneWarnings;

  { Does user want to process VRML/X3D events? Set by menu item.

    When false, this also makes Time stopped (just like
    AnimationTimePlaying = @false. IOW, always
    SceneAnimation.TimePlaying := AnimationTimePlaying and ProcessEventsWanted.)

    This is simpler for user --- ProcessEventsWanted=false is something
    stricly "stronger" than AnimationTimePlaying=false. Actually, the engine
    *could* do something otherwise, if we would allow Time to pass
    with ProcessEventsWanted=false: time-dependent  MovieTexture
    would still play, as this is not using events (also precalculated
    animation would play). }
  ProcessEventsWanted: boolean = true;

var
  AnimationTimeSpeedWhenLoading: TKamTime = 1.0;
  AnimationTimePlaying: boolean = true;
  MenuAnimationTimePlaying: TMenuItemChecked;

  { These are set by Draw right after rendering a SceneAnimation frame. }
  LastRender_RenderedShapesCount: Cardinal;
  LastRender_BoxesOcclusionQueriedCount: Cardinal;
  LastRender_VisibleShapesCount: Cardinal;

{ Helper class ---------------------------------------------------------------
  Some callbacks here require methods, so we just use this
  dummy class to add them into. }

type
  THelper = class
    class procedure OpenRecent(const FileName: string);
    class procedure GeometryChanged(Scene: TVRMLScene;
      const SomeLocalGeometryChanged: boolean);
    class procedure ViewpointsChanged(Scene: TVRMLScene);
    class procedure BoundViewpointChanged(Sender: TObject);
    class procedure PointingDeviceSensorsChange(Sender: TObject);
  end;

{ SceneManager --------------------------------------------------------------- }

type
  TV3DSceneManager = class(TV3DShadowsSceneManager)
  protected
    procedure RenderHeadLight; override;
    procedure RenderFromView3D; override;
    procedure ApplyProjection; override;
  public
    procedure InitProperties;
    function ViewerToChanges: TVisibleChanges; override;
    procedure BeforeDraw; override;
    procedure Draw; override;
  end;

var
  SceneManager: TV3DSceneManager;

procedure TV3DSceneManager.InitProperties;
begin
  InitShadowsProperties;
  BackgroundWireframe := FillModes[FillMode].BackgroundWireframe;
end;

procedure TV3DSceneManager.ApplyProjection;
begin
  inherited;

  { inherited already called appropriate TVRMLGLScene.GLProjection,
    that updated Camera.ProjectionMatrix. But we have other cameras too,
    and we want to update their ProjectionMatrix too. }
  SetProjectionMatrix(Camera.ProjectionMatrix);
end;

{ Helper functions ----------------------------------------------------------- }

procedure UpdateSelectedEnabled;
begin
  if MenuSelectedInfo <> nil then
    MenuSelectedInfo.Enabled := SelectedItem <> nil;
  if MenuSelectedOctreeStat <> nil then
    MenuSelectedOctreeStat.Enabled := SelectedItem <> nil;
  if MenuSelectedLightsInfo <> nil then
    MenuSelectedLightsInfo.Enabled := SelectedItem <> nil;
  if MenuRemoveSelectedGeometry <> nil then
    MenuRemoveSelectedGeometry.Enabled := SelectedItem <> nil;
  if MenuRemoveSelectedFace <> nil then
    MenuRemoveSelectedFace.Enabled := SelectedItem <> nil;
  if MenuEditMaterial <> nil then
    MenuEditMaterial.Enabled := SelectedItem <> nil;
  if MenuMergeCloseVertexes <> nil then
    MenuMergeCloseVertexes.Enabled := SelectedItem <> nil;
end;

function SceneOctreeCollisions: TVRMLBaseTrianglesOctree;
begin
  if (SceneAnimation <> nil) and
     (SceneAnimation.ScenesCount <> 0) and
     (SceneAnimation.FirstScene.OctreeCollisions <> nil) then
    Result := SceneAnimation.FirstScene.OctreeCollisions else
    Result := nil;
end;

function SceneOctreeRendering: TVRMLShapeOctree;
begin
  if (SceneAnimation <> nil) and
     (SceneAnimation.ScenesCount <> 0) and
     (SceneAnimation.FirstScene.OctreeRendering <> nil) then
    Result := SceneAnimation.FirstScene.OctreeRendering else
    Result := nil;
end;

{ This calls SceneManager.PrepareRender
  (that causes SceneAnimation.PrepareRender).
  Additionally, if AllowProgess and some other conditions are met,
  this shows progress of operation.

  Remember that you can call this only when gl context is already active
  (SceneAnimation.PrepareRender requires this) }
procedure PrepareRender(AllowProgress: boolean);
begin
  if AllowProgress and (SceneAnimation.ScenesCount > 1) then
    SceneManager.PrepareRender('Preparing animation') else
    SceneManager.PrepareRender;
end;

procedure SceneOctreeCreate; forward;

procedure SetCollisionCheck(const Value: boolean;
  const NeedMenuUpdate: boolean = true);
begin
  if SceneAnimation.Collides <> Value then
  begin
    SceneAnimation.Collides := Value;
    if NeedMenuUpdate then
      MenuCollisionCheck.Checked := Value;
    if SceneAnimation.Collides and
      (SceneAnimation.FirstScene.OctreeCollisions = nil) then
      SceneOctreeCreate;
  end;
end;

function ProjectionType: TProjectionType; forward;
function ViewpointNode: TVRMLViewpointNode; forward;

{ TGLWindow callbacks --------------------------------------------------------- }

procedure Init(Glwin: TGLWindow);
begin
 statusFont := TGLBitmapFont.Create(@BFNT_BitstreamVeraSansMono_Bold_m15);

 { normalize normals because we will scale our objects in Examiner navigation;
   chwilowo i tak w Scene.Render zawsze jest wlaczane glEnable(GL_NORMALIZE)
   ale to nie zawsze bedzie prawdziwe.  }
 glEnable(GL_NORMALIZE);
 glEnable(GL_DEPTH_TEST);

 { We want to be able to render any scene --- so we have to be prepared
   that fog interpolation has to be corrected for perspective. }
 glHint(GL_FOG_HINT, GL_NICEST);

 ProgressGLInterface.Window := Glw;
 Progress.UserInterface := ProgressGLInterface;

 BGColorChanged;

 ShadowsGLInit;

 AntiAliasingGLInit;
 AntiAliasingEnable;
end;

procedure Close(Glwin: TGLWindow);
begin
  ShadowsGLClose;
  FreeAndNil(statusFont);
end;

procedure DrawStatus(data: Pointer);
const
  BoolToStrOO: array[boolean] of string = ('OFF','ON');
  StatusInsideCol: TVector4f = (0, 0, 0, 0.7);
  StatusBorderCol: TVector4f = (0, 1, 0, 1);
  StatusTextCol  : TVector4f = (1, 1, 0, 1);
var
  strs: TStringList;

  { Describe pointing-device sensors (under the mouse, and also active
    one (if any)). }
  procedure DescribeSensors;

    function DescribeSensor(Sensor: TVRMLNode): string;
    var
      Desc: string;
      J: Integer;
    begin
      Result := '';

      if Sensor.NodeName <> '' then
        Result += Format('%s (%s)', [Sensor.NodeName, Sensor.NodeTypeName]) else
        Result += Format('%s', [Sensor.NodeTypeName]);

      if Sensor is TNodeX3DPointingDeviceSensorNode then
        Desc := TNodeX3DPointingDeviceSensorNode(Sensor).FdDescription.Value else
      if Sensor is TNodeAnchor then
      begin
        Desc := TNodeAnchor(Sensor).FdDescription.Value;
        for J := 0 to TNodeAnchor(Sensor).FdUrl.Count - 1 do
        begin
          if J = 0 then
          begin
            if Desc <> '' then Desc += ' ';
            Desc += '[';
          end else
            Desc += ', ';
          Desc += TNodeAnchor(Sensor).FdUrl.Items.Items[J];
        end;
        if TNodeAnchor(Sensor).FdUrl.Count <> 0 then
          Desc += ']';
      end else
        Desc := '';

      Desc := SForCaption(Desc);
      if Desc <> '' then
        Result += ' ' + Desc;
    end;

  var
    Sensors: TPointingDeviceSensorsList;
    I: Integer;
  begin
    Strs.Clear;

    if SceneAnimation.ScenesCount = 1 then
    begin
      if SceneAnimation.Scenes[0].PointingDeviceOverItem <> nil then
      begin
        Sensors := SceneAnimation.Scenes[0].PointingDeviceSensors;
        for I := 0 to Sensors.Count - 1 do
          if Sensors.Enabled(I) then
            Strs.Append('Over enabled sensor: ' + DescribeSensor(Sensors[I]));
      end;
      if SceneAnimation.Scenes[0].PointingDeviceActiveSensor <> nil then
        Strs.Append('Active sensor: ' +
          DescribeSensor(SceneAnimation.Scenes[0].PointingDeviceActiveSensor));
    end;

    if Strs.Count <> 0 then
    begin
      glLoadIdentity;
      glTranslatef(5, 0, 0);
      statusFont.PrintStringsBorderedRectTop(strs, 0,
        StatusInsideCol, StatusBorderCol, StatusTextCol,
        nil, 5, 1, 1, Glw.Height, 5);
    end;
  end;

  function CurrentAboveHeight: string;
  begin
    if SceneOctreeCollisions = nil then
      Result := 'no collisions' else
    if not WalkCamera.Gravity then
      Result := 'no gravity' else
    if not WalkCamera.IsAbove then
      Result := 'no ground beneath' else
      Result := FloatToNiceStr(WalkCamera.AboveHeight);
  end;

var
  s: string;
begin
 glLoadIdentity;
 glTranslatef(5, 5, 0);

 strs := TStringList.Create;
 try
  strs.Append(Format('Navigation mode: %s', [CameraNames[CameraMode]]));

  S := Format('Collision detection: %s', [ BoolToStrOO[SceneAnimation.Collides] ]);
  if SceneOctreeCollisions = nil then
    S += ' (octree resources released)';
  strs.Append(S);

  if SceneManager.Camera is TWalkCamera then
  begin
   strs.Append(Format('Camera: pos %s, dir %s, up %s',
     [ VectorToNiceStr(WalkCamera.Position),
       VectorToNiceStr(WalkCamera.Direction),
       VectorToNiceStr(WalkCamera.Up) ]));
   strs.Append(Format('Move speed : %f, Avatar height: %f (last height above the ground: %s)',
     [ { In view3dscene, MoveHorizontalSpeed is always equal to
         MoveVerticalSpeed (as they change when user uses Input_MoveSpeedInc/Dec).
         So it's enough to show just MoveHorizontalSpeed. }
       WalkCamera.MoveHorizontalSpeed,
       WalkCamera.CameraPreferredHeight,
       CurrentAboveHeight ]));
  end else
  begin
   strs.Append(Format('Rotation quat : %s, Move : %s, Scale : %f',
     [ VectorToNiceStr(ExamineCamera.Rotations.Vector4),
       VectorToNiceStr(ExamineCamera.MoveAmount),
       ExamineCamera.ScaleFactor ]));
  end;

  strs.Append(
    Format('Projection type : %s', [ProjectionTypeToStr[ProjectionType]]) +
    OctreeDisplayStatus);

  if SceneLightsCount = 0 then
   s := '(useless, scene has no lights)' else
   s := BoolToStrOO[SceneAnimation.Attributes.UseSceneLights];
  strs.Append(Format('Use scene lights: %s', [s]));

  { Note: there's no sense in showing here Glw.Fps.RealTime,
    since it would force me to constantly render new frames just
    to show constantly changing Glw.Fps.RealTime ...
    this makes no sense, of course.

    I also decided to show below FPS from last frame (1 / Glw.Fps.DrawSpeed),
    instead of averaged FPS (Glw.Fps.FrameTime).

    Glw.Fps.FrameTime and Glw.Fps.RealTime are visible anyway
    on window's Caption. }
  if SceneAnimation.Attributes.UseOcclusionQuery or
     SceneAnimation.Attributes.UseHierarchicalOcclusionQuery then
    S := Format(' (+ %d boxes to occl query)', [LastRender_BoxesOcclusionQueriedCount]) else
    S := '';
  strs.Append(Format('Rendered Shapes : %d%s of %d. FPS : %f',
    [ LastRender_RenderedShapesCount,
      S,
      LastRender_VisibleShapesCount,
      1 / Glw.Fps.DrawSpeed ]));

  if SceneAnimation.TimeAtLoad = 0.0 then
    S := Format('World time: %f', [SceneAnimation.Time]) else
    S := Format('World time: load time + %f = %f',
      [SceneAnimation.Time - SceneAnimation.TimeAtLoad, SceneAnimation.Time]);
  if not AnimationTimePlaying then
    S += ' (paused)';
  if not ProcessEventsWanted then
    S += ' (paused, not processing VRML events)';
  strs.Append(S);

  {statusFont.printStringsBorderedRect(strs, 0, Brown4f, Yellow4f, Black4f,
    nil, 5, 1, 1);}

  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glEnable(GL_BLEND);

    statusFont.printStringsBorderedRect(strs, 0,
      StatusInsideCol, StatusBorderCol, StatusTextCol,
      nil, 5, 1, 1);

    DescribeSensors;

  glDisable(GL_BLEND);
 finally strs.Free end;
end;

procedure TV3DSceneManager.RenderHeadLight;
begin
  { Set properties of headlight. Actual enabled state of headlight will be
    set later by BeginRenderSceneWithLights inside RenderFromView3D. }
  if (SceneHeadlight <> nil) then
    SceneHeadlight.Render(0, false, RenderState.Target = rtScreen,
      SceneManager.Camera);
end;

function TV3DSceneManager.ViewerToChanges: TVisibleChanges;
begin
  if HeadLight then
    Result := [vcVisibleNonGeometry] else
    Result := [];
end;

procedure TV3DSceneManager.RenderFromView3D;

  procedure DrawFrustum(AlwaysVisible: boolean);
  var
    FrustumPoints: TFrustumPointsDouble;
  begin
    if AlwaysVisible then
    begin
      glPushAttrib(GL_ENABLE_BIT);
      glDisable(GL_DEPTH_TEST);
    end;
    try
      WalkCamera.Frustum.CalculatePoints(FrustumPoints);
      glColor3f(1, 1, 1);
      glEnableClientState(GL_VERTEX_ARRAY);
        glVertexPointer(4, GL_DOUBLE, 0, @FrustumPoints);
        glDrawElements(GL_LINES, 12 * 2, GL_UNSIGNED_INT,
          @FrustumPointsLinesIndexes);
      glDisableClientState(GL_VERTEX_ARRAY);
    finally
      if AlwaysVisible then glPopAttrib;
    end;
  end;

begin
  { In methods other than bmGLSLAll, setting Scene.BumpMappingLightPosition
    may be costly operation. So don't do this. }
  if MainScene.BumpMappingMethod in bmGLSLAll then
    MainScene.BumpMappingLightPosition := SceneManager.Camera.GetPosition;

  BeginRenderSceneWithLights(SceneAnimation);

    if FillMode = fmSilhouetteBorderEdges then
      RenderSilhouetteBorderEdges(Vector4Single(WalkCamera.Position, 1), MainScene) else
    begin
      { Scene.RenderFrustum (inside inherited)
        will automatically use octree, if available.
        Note that octree may be not available (for animations,
        OctreeRendering is constructed only for the 1st scene.
        Also, generation of octree may be turned off for
        speed purposes.) }

      inherited;

      LastRender_RenderedShapesCount := MainScene.LastRender_RenderedShapesCount;
      LastRender_BoxesOcclusionQueriedCount := MainScene.LastRender_BoxesOcclusionQueriedCount;
      LastRender_VisibleShapesCount  := MainScene.LastRender_VisibleShapesCount;
    end;

  EndRenderSceneWithLights;

  OctreeDisplay(SceneAnimation);

  if RenderState.Target = rtScreen then
  begin
    if showBBox and (not MakingScreenShot) then
    begin
      { Display current bounding box only if there's a chance that it's
        different than whole animation BoundingBox --- this requires that animation
        has at least two frames. }
      if SceneAnimation.ScenesCount > 1 then
      begin
        glColorv(Red3Single);
        if not IsEmptyBox3D(SceneAnimation.CurrentScene.BoundingBox) then
          glDrawBox3DWire(SceneAnimation.CurrentScene.BoundingBox);
      end;

      glColorv(Green3Single);
      if not IsEmptyBox3D(SceneAnimation.BoundingBox) then
        glDrawBox3DWire(SceneAnimation.BoundingBox);
    end;

    { Note that there is no sense in showing viewing frustum in
      CameraMode <> cmExamine, since viewing frustum should
      be never visible then (or should be just at the exact borders
      or visibility, so it's actually unspecified whether OpenGL would
      show it or not). }
    if ShowFrustum and (CameraMode = cmExamine) then
     DrawFrustum(ShowFrustumAlwaysVisible);

    if SelectedItem <> nil then
    begin
      if not GLVersion.BuggyPointSetAttrib then
        glPushAttrib(GL_ENABLE_BIT or GL_LINE_BIT or GL_POINT_BIT) else
        glPushAttrib(GL_ENABLE_BIT or GL_LINE_BIT);

        glDisable(GL_DEPTH_TEST); { saved by GL_ENABLE_BIT }
        glColorv(White3Single);

        glLineWidth(3.0); { saved by GL_LINE_BIT }
        glBegin(GL_LINE_LOOP);
          glVertexv(SelectedItem^.World.Triangle[0]);
          glVertexv(SelectedItem^.World.Triangle[1]);
          glVertexv(SelectedItem^.World.Triangle[2]);
        glEnd;

        glPointSize(5.0); { saved by GL_POINT_BIT }
        glBegin(GL_POINTS);
          glVertexv(SelectedPointWorld);
        glEnd;
      glPopAttrib;
    end;
  end;
end;

procedure TV3DSceneManager.BeforeDraw;
begin
  { Make sure to call InitProperties before inherited. }
  InitProperties;
  inherited;
end;

procedure TV3DSceneManager.Draw;
begin
  { Make sure to call InitProperties before inherited. }
  InitProperties;
  inherited;
end;

procedure Draw(Glwin: TGLWindow);
begin
  if ShowStatus and (not MakingScreenShot) then
  begin
    { Note that DrawStatus changes current modelview matrix,
      so you want to always leave drawing status at the end of this Draw
      procedure. }
    glPushAttrib(GL_ENABLE_BIT);
      glDisable(GL_DEPTH_TEST);
      glProjectionPushPopOrtho2D(@DrawStatus, nil, 0, Glwin.Width, 0, Glwin.Height);
    glPopAttrib;
  end;
end;

const
  SOnlyInWalker = 'You must be in ''Walk'' navigation mode '+
    'to use this function.';

  SOnlyWhenOctreeAvailable = 'This is not possible when octree is not generated. Turn on "Navigation -> Collision Detection" to make it available.';

procedure MouseDown(Glwin: TGLWindow; btn: TMouseButton);
var
  Ray0, RayVector: TVector3Single;
begin
  if (btn = mbRight) and
     { Support selecting item by right button click only in Walk mode.

       In Examine mode, it would collide with zooming in / out,
       making  user select item on each zoom in / out by dragging
       right mouse button. Mouse clicks start dragging, so don't do
       anything here (not even a warning about SOnlyInWalker,
       since it would only interfere with navigation). }
     (SceneManager.Camera is TWalkCamera) then
  begin
    if SceneOctreeCollisions = nil then
    begin
      MessageOK(Glwin, SOnlyWhenOctreeAvailable, taLeft);
      Exit;
    end;

    SceneManager.Camera.MouseRay(
      SceneManager.PerspectiveView, SceneManager.PerspectiveViewAngles,
      SceneManager.OrthoViewDimensions, Ray0, RayVector);

    SelectedItem := SceneOctreeCollisions.RayCollision(
      SelectedPointWorld, Ray0, RayVector, true, nil, false, nil);

    { calculate SelectedPointLocal }
    if SelectedItem <> nil then
    begin
      try
        SelectedPointLocal := MatrixMultPoint(
          SelectedItem^.State.InvertedTransform, SelectedPointWorld);
      except
        on ETransformedResultInvalid do
          SelectedItem := nil;
      end;
    end;

    { DirectCollisionTestsCounter is not recorded,
      so I may write it now on console in case it will be useful.
      For now it's commented out --- not interesting to typical user.
    Writeln(Format('%d tests for collisions between ray ' +
      'and triangles were needed to learn this.',
      [ SceneOctreeCollisions.DirectCollisionTestsCounter ])); }

    UpdateSelectedEnabled;

    Glw.PostRedisplay;
  end;
end;

class procedure THelper.PointingDeviceSensorsChange(Sender: TObject);
begin
  { Our status text displays current sensors (under the mouse,
    and currently active (if any)), so we have to redisplay. }
  Glw.PostRedisplay;
end;

{ Setting viewpoint ---------------------------------------------------------- }

function NavigationNode: TNodeNavigationInfo;
begin
  if SceneAnimation.Loaded then
    Result := SceneAnimation.Scenes[0].NavigationInfoStack.Top as
      TNodeNavigationInfo else
    Result := nil;
end;

function ViewpointNode: TVRMLViewpointNode;
begin
  if SceneAnimation.Loaded then
    Result := SceneAnimation.Scenes[0].ViewpointStack.Top as
      TVRMLViewpointNode else
    Result := nil;
end;

function ProjectionType: TProjectionType;
var
  Viewpoint: TVRMLViewpointNode;
begin
  Viewpoint := ViewpointNode;
  if Viewpoint <> nil then
    Result := Viewpoint.ProjectionType else
    Result := ptPerspective;
end;

{ This directly sets camera properties, without looking at
  current ViewpointNode state. It may be used to initialize
  camera to some state that doesn't correspond to any existing
  viewpoint, or as a basis for UpdateViewpointNode.

  This takes into account NavigationNode, that is currently bound
  NavigationInfo node.

  Besides initializing camera by WalkCamera.Init, it also
  takes care to initialize MoveHorizontal/VerticalSpeed.

  Note that the length of InitialDirection doesn't matter. }
procedure SetViewpointCore(
  const InitialPosition: TVector3Single;
  InitialDirection: TVector3Single;
  const InitialUp: TVector3Single;
  const GravityUp: TVector3Single);
begin
  { Change InitialDirection length, to adjust speed.
    Also set MoveHorizontal/VerticalSpeed. }

  if NavigationNode = nil then
  begin
    { Since we don't have NavigationNode.speed, we just calculate some
      speed that should "feel sensible". We base it on CameraRadius.
      CameraRadius in turn was calculated based on
      Box3DAvgSize(SceneAnimation.BoundingBox). }
    VectorAdjustToLengthTo1st(InitialDirection, WalkCamera.CameraRadius * 0.8);
    WalkCamera.MoveHorizontalSpeed := 1;
    WalkCamera.MoveVerticalSpeed := 1;
  end else
  if NavigationNode.FdSpeed.Value = 0 then
  begin
    { Then user is not allowed to move at all.

      InitialDirection must be non-zero (we normalize it just to satisfy
      requirement that "length of InitialDirection doesn't matter" here,
      in case user will later increase move speed by menu anyway.

      So we do this is by setting MoveHorizontal/VerticalSpeed to zero.
      This is also the reason why other SetViewpointCore must change
      MoveHorizontal/VerticalSpeed to something different than zero
      (otherwise, user would be stuck with speed = 0). }
    NormalizeTo1st(InitialDirection);
    WalkCamera.MoveHorizontalSpeed := 0;
    WalkCamera.MoveVerticalSpeed := 0;
  end else
  begin
    { view3dscene versions (<= 2.2.1) handled NavigationInfo.speed badly.
      They set InitialDirection length to
        CameraRadius * 0.4 * NavigationNode.FdSpeed.Value
      Effectively, speed per second was
        CameraRadius * 0.4 * NavigationNode.FdSpeed.Value * 50 / second
      If your VRML models were adjusted to this view3dscene broken handling,
      you should fix NavigationInfo.speed to value below to get the same speed
      in newer view3dscene versions :
    Writeln('Fix NavigationInfo.speed to ',
      FloatToRawStr(CameraRadius * 0.4 * NavigationNode.FdSpeed.Value * 50));
    }

    VectorAdjustToLengthTo1st(InitialDirection, NavigationNode.FdSpeed.Value / 50.0);
    WalkCamera.MoveHorizontalSpeed := 1;
    WalkCamera.MoveVerticalSpeed := 1;
  end;

  WalkCamera.Init(InitialPosition, InitialDirection, InitialUp,
    GravityUp, WalkCamera.CameraPreferredHeight, WalkCamera.CameraRadius);

  if not Glw.Closed then
  begin
    Glw.EventResize;
    Glw.PostRedisplay;
  end;
end;

{ Call this when ViewpointNode (currently bound viewpoint node)
  changed (possibly to/from nil) and we have to go to this viewpoint.

  When it's nil, we'll go to some default position.

  This does update the ViewpointsList menu.

  This doesn't call set_bind event for this viewpoint --- the idea
  is that viewpoint changed for example because something already
  did set_bind. If you want to just bind the viewpoint, then
  don't use this procedure --- instead send set_bind = true event
  to given viewpoint, and this will indirectly call this procedure.

  Uses WalkCamera.CameraRadius, NavigationNode, so make sure these are already
  set as needed }
procedure UpdateViewpointNode;
var
  Position: TVector3Single;
  Direction: TVector3Single;
  Up: TVector3Single;
  GravityUp: TVector3Single;
  V: TVRMLViewpointNode;
begin
  V := ViewpointNode;
  if V <> nil then
  begin
    V.GetCameraVectors(Position, Direction, Up, GravityUp);
  end else
  begin
    Position := DefaultVRMLCameraPosition[1];
    Direction := DefaultVRMLCameraDirection;
    Up := DefaultVRMLCameraUp;
    GravityUp := DefaultVRMLGravityUp;
  end;

  ViewpointsList.BoundViewpoint := V;

  SetViewpointCore(Position, Direction, Up, GravityUp);
end;

class procedure THelper.ViewpointsChanged(Scene: TVRMLScene);
begin
  ViewpointsList.Recalculate(Scene);
end;

class procedure THelper.BoundViewpointChanged(Sender: TObject);
begin
  ViewpointsList.BoundViewpoint := SceneManager.MainScene.ViewpointStack.Top
    as TVRMLViewpointNode;
end;

{ Scene operations ---------------------------------------------------------- }

var
  { This is set to non-nil by CreateMainMenu.
    It is used there and it is also used from LoadSceneCore, since
    loading a scene may change some values (like HeadLight, Gravity etc.)
    so we have to update MenuHeadlight.Checked (and other menu's) state. }
  MenuHeadlight, MenuGravity, MenuIgnoreAllInputs: TMenuItemChecked;
  MenuPreferGravityUpForRotations: TMenuItemChecked;
  MenuPreferGravityUpForMoving: TMenuItemChecked;
  MenuReopen: TMenuItem;

  DebugLogVRMLChanges: boolean = false;

procedure DoVRMLWarning(const WarningType: TVRMLWarningType; const s: string);
begin
  { Write to ErrOutput, not normal Output, since when --write-to-vrml was used,
    we write to output VRML contents. }
  Writeln(ErrOutput, ProgramName + ': VRML Warning: ' + S);
  SceneWarnings.Add(S);
end;

procedure DoDataWarning(const s: string);
begin
  { Write to ErrOutput, not normal Output, since when --write-to-vrml was used,
    we write to output VRML contents. }
  Writeln(ErrOutput, ProgramName + ': Data Warning: ' + S);
  SceneWarnings.Add(S);
end;

procedure SceneOctreeCreate;
var
  OldDraw, OldBeforeDraw: TDrawFunc;
begin
  { Do not create octrees when SceneAnimation.Collides = false. This makes
    setting SceneAnimation.Collides to false an optimization: octree doesn't have to
    be recomputed when animation frame changes, or new scene is loaded etc. }

  if SceneAnimation.Collides then
  begin
    { Beware: constructing octrees will cause progress drawing,
      and progress drawing may cause FlushRedisplay,
      and FlushRedisplay may cause OnDraw and OnBeforeDraw to be called.
      That's why we simply turn normal Draw/BeforeDraw temporarily off. }
    OldDraw := Glw.OnDraw;
    OldBeforeDraw := Glw.OnBeforeDraw;
    Glw.OnDraw := nil;
    Glw.OnBeforeDraw := nil;
    try
      { For now we construct and store octrees only for the 1st animation frame. }

      SceneAnimation.FirstScene.TriangleOctreeProgressTitle := 'Building triangle octree';
      SceneAnimation.FirstScene.ShapeOctreeProgressTitle := 'Building Shape octree';
      SceneAnimation.FirstScene.Spatial := [ssRendering, ssDynamicCollisions];
    finally
      Glw.OnDraw := OldDraw;
      Glw.OnBeforeDraw := OldBeforeDraw;
    end;
  end;
end;

procedure SceneOctreeFree;
begin
  if SceneAnimation.ScenesCount <> 0 then
  begin
    { Since we destroy our PVRMLTriangles, make sure SceneAnimation.FirstScene
      doesn't hold a reference to it.

      Note: PointingDeviceClear will automatically update current cursor
      (by calling OnPointingDeviceSensorsChange that leads to our method). }
    SceneAnimation.FirstScene.PointingDeviceClear;

    SceneAnimation.FirstScene.Spatial := [];
  end;
end;

procedure Unselect;
begin
  SelectedItem := nil;
  UpdateSelectedEnabled;
end;

{ Frees (and sets to some null values) "scene global variables".

  Note about OpenGL context: remember that calling Close
  on SceneAnimation also calls GLContextClose  that closes all connections
  of Scene to OpenGL context. This means that:
  1) SceneAnimation must not be Loaded, or Scene must not have any
     connections with OpenGL context (like e.g. after calling
     SceneAnimation.GLContextClose)
  2) or you must call FreeScene in the same OpenGL context that the
     SceneAnimation is connected to. }
procedure FreeScene;
begin
  SceneOctreeFree;

  SceneAnimation.Close;
  { SceneAnimation.Close must free all scenes, including FirstScene,
    which should (through free notification) set to nil also
    SceneManager.MainScene }
  Assert(SceneManager.MainScene = nil);

  ViewpointsList.Recalculate(nil);

  SceneFileName := '';

  if MenuReopen <> nil then
    MenuReopen.Enabled := false;

  Unselect;

  FreeAndNil(SceneHeadlight);
end;

{ Update state of ProcessEvents for all SceneAnimation.Scenes[].

  This looks at ProcessEventsWanted and SceneAnimation.ScenesCount,
  so should be repeated when they change, and when new Scenes[] are loaded. }
procedure UpdateProcessEvents;
var
  I: Integer;
  Value: boolean;
begin
  { Always disable ProcessEvents for TVRMLGLAnimation consisting of many models. }
  Value := ProcessEventsWanted and (SceneAnimation.ScenesCount = 1);

  for I := 0 to SceneAnimation.ScenesCount - 1 do
    SceneAnimation.Scenes[I].ProcessEvents := Value;
end;

procedure LoadClearScene; forward;

{ Calls FreeScene and then inits "scene global variables".
  Pass here ACameraRadius = 0.0 to say that CameraRadius should be
  somehow calculated (guessed) based on loaded Scene data.

  Camera settings for scene are inited from VRML defaults and
  from camera node in scene.

  Exceptions: if this function will raise any exception you should assume
  that scene loading failed for some reason and "scene global variables"
  are set to their "null values". I.e. everything is in a "clean" state
  like after FreeScene.

  This procedure does not really open any file
  (so ASceneFileName need not be a name of existing file,
  in fact it does not need to even be a valid filename).
  Instead in uses already created RootNode to init
  "scene global variables".

  Note that all RootNodes[] will be owned by Scene.
  So do not Free RootNodes[] items after using this procedure
  (still, you should use RootNodes list itself).

  Note that this may change the value of Times list.

  Note that there is one "scene global variable" that will
  not be completely handled by this procedure:
  SceneWarnings. During this procedure some VRML warnings may
  occur and be appended to SceneWarnings. You have to take care
  about the rest of issues with the SceneWarnings, like clearing
  them before calling LoadSceneCore.

  ASceneFileName is not const parameter, to allow you to pass
  SceneFileName as ASceneFileName. If ASceneFileName would be const
  we would have problem, because FreeScene modifies SceneFileName
  global variable, and this would change ASceneFileName value
  (actually, making it possibly totally invalid pointer,
  pointing at some other place of memory). That's always the
  problem with passing pointers to global variables
  (ASceneFileName is a pointer) as local vars.

  If UseInitialNavigationType then we will use and reset
  InitialNavigationType. This should be @false if you're only loading
  temporary scene, like LoadClearScene. }
procedure LoadSceneCore(
  RootNodes: TVRMLNodesList;
  ATimes: TDynSingleArray;
  ScenesPerTime: Cardinal;
  NewOptimization: TGLRendererOptimization;
  const EqualityEpsilon: Single;
  TimeLoop, TimeBackwards: boolean;

  ASceneFileName: string;
  const SceneChanges: TSceneChanges; const ACameraRadius: Single;
  JumpToInitialViewpoint: boolean;

  UseInitialNavigationType: boolean = true);

  procedure ScaleAll(A: TDynSingleArray; const Value: Single);
  var
    I: Integer;
  begin
    for I := 0 to A.High do
      A.Items[I] *= Value;
  end;

  { Set CameraMode and related camera properties, based on
    NavigationNode.FdType }
  procedure SetNavigationType;

    { Set navigation type by SetCameraMode, also setting
      WalkCamera.PreferGravityUpForRotations
      WalkCamera.PreferGravityUpForMoving,
      WalkCamera.Gravity,
      WalkCamera.IgnoreAllInputs.

      Returns @false and doesn't set anything (but does VRMLWarning)
      if Name unknown. }
    function DoSetNavigationType(Name: string): boolean;
    begin
      Name := UpperCase(Name); { ignore case when looking for name }
      Result := true;
      if Name = 'WALK' then
      begin
        SetCameraMode(SceneManager, cmWalk);
        WalkCamera.PreferGravityUpForRotations := true;
        WalkCamera.PreferGravityUpForMoving := true;
        WalkCamera.Gravity := true;
        WalkCamera.IgnoreAllInputs := false;
      end else
      if Name = 'FLY' then
      begin
        SetCameraMode(SceneManager, cmWalk);
        WalkCamera.PreferGravityUpForRotations := true;
        WalkCamera.PreferGravityUpForMoving := false;
        WalkCamera.Gravity := false;
        WalkCamera.IgnoreAllInputs := false;
      end else
      if Name = 'NONE' then
      begin
        SetCameraMode(SceneManager, cmWalk);
        WalkCamera.PreferGravityUpForRotations := true;
        WalkCamera.PreferGravityUpForMoving := true; { doesn't matter }
        WalkCamera.Gravity := false;
        WalkCamera.IgnoreAllInputs := true;
      end else
      if (Name = 'EXAMINE') or (Name = 'LOOKAT') then
      begin
        if Name = 'LOOKAT' then
          VRMLWarning(vwIgnorable, 'TODO: Navigation type "LOOKAT" is not yet supported, treating like "EXAMINE"');

        SetCameraMode(SceneManager, cmExamine);

        { Set also WalkCamera properties to something predictable
          (*not* dependent on previous values, as this would be rather
          confusing to user (new model should just start with new settings).
          In particular, IgnoreAllInputs must be reset.)

          Values below are like for "FLY" mode, since this is relatively
          safest default for WalkCamera (free navigation, no gravity). }

        WalkCamera.PreferGravityUpForRotations := true;
        WalkCamera.PreferGravityUpForMoving := false;
        WalkCamera.Gravity := false;
        WalkCamera.IgnoreAllInputs := false;
      end else
      if Name = 'ANY' then
      begin
        { Just ignore (do not set camera), but accept as valid name
          (no VRMLWarning). }
        Result := false;
      end else
      begin
        VRMLWarning(vwIgnorable, 'Invalid navigation type name "' + Name + '"');
        Result := false;
      end;
    end;

  var
    FoundType: boolean;
    I: Integer;
  begin
    FoundType := false;
    if NavigationNode <> nil then
      for I := 0 to NavigationNode.FdType.Count - 1 do
        if DoSetNavigationType(NavigationNode.FdType.Items[I]) then
        begin
          FoundType := true;
          Break;
        end;

    if not FoundType then
    begin
      if UseInitialNavigationType and (InitialNavigationType <> '') then
      begin
        FoundType := DoSetNavigationType(InitialNavigationType);
        InitialNavigationType := '';
      end;

      if not FoundType then
        DoSetNavigationType('EXAMINE');
    end;

    if MenuGravity <> nil then
      MenuGravity.Checked := WalkCamera.Gravity;
    if MenuIgnoreAllInputs <> nil then
      MenuIgnoreAllInputs.Checked := WalkCamera.IgnoreAllInputs;
    if MenuPreferGravityUpForRotations <> nil then
      MenuPreferGravityUpForRotations.Checked := WalkCamera.PreferGravityUpForRotations;
    if MenuPreferGravityUpForMoving <> nil then
      MenuPreferGravityUpForMoving.Checked := WalkCamera.PreferGravityUpForMoving;
  end;

var
  NewCaption: string;
  CameraPreferredHeight, CameraRadius: Single;
  WorldInfoNode: TNodeWorldInfo;
  I: Integer;
  SavedPosition, SavedDirection, SavedUp, SavedGravityUp: TVector3Single;
begin
  FreeScene;

  try
    SceneFileName := ASceneFileName;

    if AnimationTimeSpeedWhenLoading <> 1.0 then
      ScaleAll(ATimes, 1 / AnimationTimeSpeedWhenLoading);

    { Optimization is changed here, as it's best to do it when scene
      is not loaded. }
    Optimization := NewOptimization;
    if OptimizationMenu[Optimization] <> nil then
      OptimizationMenu[Optimization].Checked := true;
    SceneAnimation.Optimization := Optimization;

    SceneAnimation.Load(RootNodes, true, ATimes,
      ScenesPerTime, EqualityEpsilon);
    SceneAnimation.TimeLoop := TimeLoop;
    SceneAnimation.TimeBackwards := TimeBackwards;
    { do it before even assigning MainScene, as assigning MainScene may
      (through VisibleChange notification) already want to refer
      to current animation scene, so better make it sensible. }
    SceneAnimation.ResetTimeAtLoad;

    { assign SceneManager.MainScene relatively early, because our
      rendering assumes that SceneManager.MainScene is usable,
      and rendering may be called during progress bars even from this function. }
    SceneManager.MainScene := SceneAnimation.FirstScene;

    ChangeSceneAnimation(SceneChanges, SceneAnimation);

    { calculate CameraRadius }
    CameraRadius := ACameraRadius;
    if CameraRadius = 0.0 then
    begin
      if (NavigationNode <> nil) and (NavigationNode.FdAvatarSize.Count >= 1) then
        CameraRadius := NavigationNode.FdAvatarSize.Items[0];
      if CameraRadius = 0.0 then
        CameraRadius := Box3DAvgSize(SceneAnimation.BoundingBox,
          1.0 { any non-zero dummy value }) * 0.005;
    end;

    { calculate CameraPreferredHeight }
    if (NavigationNode <> nil) and (NavigationNode.FdAvatarSize.Count >= 2) then
      CameraPreferredHeight := NavigationNode.FdAvatarSize.Items[1] else
      { Make it something >> CameraRadius * 2, to allow some
        space to decrease (e.g. by Input_DecreaseCameraPreferredHeight
        in view3dscene). Remember that CorrectCameraPreferredHeight
        adds a limit to CameraPreferredHeight, around CameraRadius * 2. }
      CameraPreferredHeight := CameraRadius * 4;

    { calculate HeadBobbing* }
    if (NavigationNode <> nil) and
       (NavigationNode is TNodeKambiNavigationInfo) then
    begin
      WalkCamera.HeadBobbing := TNodeKambiNavigationInfo(NavigationNode).FdHeadBobbing.Value;
      WalkCamera.HeadBobbingDistance := TNodeKambiNavigationInfo(NavigationNode).FdHeadBobbingDistance.Value;
    end else
    begin
      WalkCamera.HeadBobbing := DefaultHeadBobbing;
      WalkCamera.HeadBobbingDistance := DefaultHeadBobbingDistance;
    end;

    if not JumpToInitialViewpoint then
    begin
      { TODO: this should preserve previously bound viewpoint. }
      SavedPosition := WalkCamera.Position;
      SavedDirection := WalkCamera.Direction;
      SavedUp := WalkCamera.Up;
      SavedGravityUp := WalkCamera.GravityUp;
    end;

    SceneInitCameras(SceneAnimation.BoundingBox,
      DefaultVRMLCameraPosition[1],
      DefaultVRMLCameraDirection,
      DefaultVRMLCameraUp,
      DefaultVRMLGravityUp,
      CameraPreferredHeight, CameraRadius);

    { calculate ViewpointsList, including MenuJumpToViewpoint,
      and jump to 1st viewpoint (or to the default cam settings). }
    ViewpointsList.Recalculate(SceneAnimation.FirstScene);
    UpdateViewpointNode;

    if not JumpToInitialViewpoint then
    begin
      WalkCamera.Position := SavedPosition;
      WalkCamera.Direction := SavedDirection;
      WalkCamera.Up := SavedUp;
      WalkCamera.GravityUp := SavedGravityUp;
    end;

    SceneInitLights(SceneAnimation, NavigationNode);
    SceneHeadlight := SceneAnimation.FirstScene.CreateHeadLight;

    { SceneInitLights could change HeadLight value.
      So update MenuHeadlight.Checked now. }
    if MenuHeadlight <> nil then
      MenuHeadlight.Checked := HeadLight;

    WorldInfoNode := SceneAnimation.FirstScene.RootNode.TryFindNode(
      TNodeWorldInfo, true)
      as TNodeWorldInfo;
    if (WorldInfoNode <> nil) and (WorldInfoNode.FdTitle.Value <> '') then
      NewCaption := SForCaption(WorldInfoNode.FdTitle.Value) else
      NewCaption := ExtractFileName(SceneFilename);
    NewCaption += ' - view3dscene';
    if Glw.Closed then
      Glw.Caption := NewCaption else
      Glw.FPSBaseCaption := NewCaption;

    SetNavigationType;

    SceneOctreeCreate;

    for I := 0 to SceneAnimation.ScenesCount - 1 do
    begin
      { Order is somewhat important here: first turn DebugLogVRMLChanges on,
        then turn events on, otherwise events on initialize() of scripts
        will not be logged. }
      SceneAnimation.Scenes[I].LogChanges := DebugLogVRMLChanges;

      SceneAnimation.Scenes[I].OnGeometryChanged := @THelper(nil).GeometryChanged;
      SceneAnimation.Scenes[I].OnViewpointsChanged := @THelper(nil).ViewpointsChanged;
      SceneAnimation.Scenes[I].OnPointingDeviceSensorsChange := @THelper(nil).PointingDeviceSensorsChange;

      { regardless of ProcessEvents, we may change the vrml graph,
        e.g. by Edit->Material->... }
      SceneAnimation.Scenes[I].Static := SceneAnimation.ScenesCount <> 1;
    end;

    UpdateProcessEvents;

    { Make initial ViewerChanged to make initial events to
      ProximitySensor, if user is within. }
    SceneAnimation.Scenes[0].ViewerChanged(SceneManager.Camera, SceneManager.ViewerToChanges);

    if not Glw.Closed then
    begin
      { call EventResize to adjust zNear/zFar of our projection to the size
        of Scene.BoundingBox }
      Glw.EventResize;
      SceneAnimation.Scenes[0].VisibleChangeHere([]);
    end;

    if MenuReopen <> nil then
      MenuReopen.Enabled := SceneFileName <> '';
  except
    FreeScene;
    raise;
  end;
end;

{ This loads the scene from file (using LoadVRMLSequence) and
  then inits our scene variables by LoadSceneCore.

  If it fails, it tries to preserve current scene
  (if it can't preserve current scene, only then it resets it to clear scene).
  Also, it shows the error message using MessageOK
  (so Glw must be already open).

  It may seem that ASceneFileName could be constant parameter here.
  Yes, it could. However, you will sometimes want to pass here
  SceneFileName global value and this would cause memory havoc
  (parameter is passed as const, however when global variable
  SceneFileName is changed then the parameter value implicitly
  changes, it may even cause suddenly invalid pointer --- yeah,
  I experienced it). }
procedure LoadScene(ASceneFileName: string;
  const SceneChanges: TSceneChanges; const ACameraRadius: Single;
  JumpToInitialViewpoint: boolean);

{ It's useful to undefine it only for debug purposes:
  FPC dumps then backtrace of where exception happened,
  which is often enough to trace the error.
  In release versions this should be defined to produce a nice
  message box in case of errors (instead of just a crash). }
{$define CATCH_EXCEPTIONS}

var
  RootNodes: TVRMLNodesList;
  Times: TDynSingleArray;
  ScenesPerTime: Cardinal;
  EqualityEpsilon: Single;
  TimeLoop, TimeBackwards: boolean;
  NewOptimization: TGLRendererOptimization;
  SavedSceneWarnings: TSceneWarnings;
begin
  RootNodes := TVRMLNodesList.Create;
  Times := TDynSingleArray.Create;
  try
    { TODO: Show to user that optimization for kanim is from kanim file,
      not current setting of Optimization ?
      Optimization is now user's preference,
      but we silently override it when loading from KAnim file - not nice. }

    NewOptimization := Optimization;

    { We have to clear SceneWarnings here (not later)
      to catch also all warnings raised during parsing the VRML file.
      This causes a potential problem: if loading the scene will fail,
      we should restore the old warnings (if the old scene will be
      preserved) or clear them (if the clear scene will be loaded
      --- LoadClearScene will clear them). }
    SavedSceneWarnings := TSceneWarnings.Create;
    try
      SavedSceneWarnings.Assign(SceneWarnings);
      SceneWarnings.Clear;

      {$ifdef CATCH_EXCEPTIONS}
      try
      {$endif CATCH_EXCEPTIONS}
        LoadVRMLSequence(ASceneFileName, true,
          RootNodes, Times,
          ScenesPerTime, NewOptimization, EqualityEpsilon,
          TimeLoop, TimeBackwards);
      {$ifdef CATCH_EXCEPTIONS}
      except
        on E: Exception do
        begin
          MessageOK(glw, 'Error while loading scene from "' +ASceneFileName+ '": ' +
            E.Message, taLeft);
          { In this case we can preserve current scene. }
          SceneWarnings.Assign(SavedSceneWarnings);
          Exit;
        end;
      end;
      {$endif CATCH_EXCEPTIONS}
    finally FreeAndNil(SavedSceneWarnings) end;

    {$ifdef CATCH_EXCEPTIONS}
    try
    {$endif CATCH_EXCEPTIONS}
      LoadSceneCore(
        RootNodes, Times,
        ScenesPerTime, NewOptimization, EqualityEpsilon,
        TimeLoop, TimeBackwards,
        ASceneFileName, SceneChanges, ACameraRadius, JumpToInitialViewpoint);
    {$ifdef CATCH_EXCEPTIONS}
    except
      on E: Exception do
      begin
        { In this case we cannot preserve old scene, because
          LoadSceneCore does FreeScene when it exits with exception
          (and that's because LoadSceneCore modifies some global scene variables
          when it works --- so when something fails inside LoadSceneCore,
          we are left with some partially-initiaized state,
          that is not usable; actually, LoadSceneCore
          also does FreeScene when it starts it's work --- to start
          with a clean state).

          We call LoadClearScene before we call MessageOK, this way
          our Draw routine works OK when it's called to draw background
          under MessageOK. }
        LoadClearScene;
        MessageOK(glw, 'Error while loading scene from "' + ASceneFileName + '": ' +
          E.Message, taLeft);
        Exit;
      end;
    end;
    {$endif CATCH_EXCEPTIONS}

    { For batch operation (making screenshots), do not save the scene
      on "recent files" menu. This also applies when using view3dscene
      as a thumbnailer. }
    if not MakingScreenShot then
      RecentMenu.Add(ASceneFileName);

    { We call PrepareRender to make SceneAnimation.PrepareRender to gather
      VRML warnings (because some warnings, e.g. invalid texture filename,
      are reported only from SceneAnimation.PrepareRender).
      Also, this allows us to show first PrepareRender with progress bar. }
    PrepareRender(true);
    if (SceneWarnings.Count <> 0) and
       { For MakingScreenShot, work non-interactively.
         Warnings are displayed at stderr anyway, so user will see them there. }
       (not MakingScreenShot) then
      MessageOK(Glw, Format('Note that there were %d warnings while loading ' +
        'this scene. See the console or use File->"View warnings" ' +
        'menu command to view them all.', [SceneWarnings.Count]), taLeft);
  finally
    FreeAndNil(RootNodes);
    FreeAndNil(Times);
  end;
end;

{ This should be used to load special "clear" and "welcome" scenes.
  This loads a scene directly from TVRMLNode, and assumes that
  LoadSceneCore will not fail. }
procedure LoadSimpleScene(Node: TVRMLNode;
  UseInitialNavigationType: boolean = true);
var
  RootNodes: TVRMLNodesList;
  Times: TDynSingleArray;
  ScenesPerTime: Cardinal;
  EqualityEpsilon: Single;
  TimeLoop, TimeBackwards: boolean;
begin
  RootNodes := TVRMLNodesList.Create;
  Times := TDynSingleArray.Create;
  try
    RootNodes.Add(Node);
    Times.Add(0);

    ScenesPerTime := 1;      { doesn't matter }
    EqualityEpsilon := 0.0;  { doesn't matter }
    TimeLoop := false;      { doesn't matter }
    TimeBackwards := false; { doesn't matter }

    SceneWarnings.Clear;
    LoadSceneCore(
      RootNodes, Times,
      ScenesPerTime,
      { keep current Optimization } Optimization,
      EqualityEpsilon,
      TimeLoop, TimeBackwards,
      '', [], 1.0, true,
      UseInitialNavigationType);
  finally
    FreeAndNil(RootNodes);
    FreeAndNil(Times);
  end;
end;

{ This works like LoadScene, but loaded scene is an empty scene.
  More specifically, this calls FreeScene, and then inits
  "scene global variables" to some non-null values. }
procedure LoadClearScene;
begin
  { As a clear scene, I'm simply loading an empty VRML file.
    This way everything seems normal: SceneAnimation is Loaded,
    FirstScene is available and FirstScene.RootNode is non-nil.

    The other idea was to use some special state like Loaded = @false
    to indicate clear scene, but this would only complicate code
    with checks for "if Loaded" everywhere.

    Also, non-empty clear scene allows me to put there WorldInfo with a title.
    This way clear scene has an effect on view3dscene window's title,
    and at the same time I don't have to set SceneFileName to something
    dummy.

    I'm not constructing here RootNode in code (i.e. Pascal).
    This would allow a fast implementation, but it's easier for me to
    design scene in pure VRML and then auto-generate
    xxx_scene.inc file to load VRML scene from a simple string. }
  LoadSimpleScene(LoadVRMLClassicFromString({$I clear_scene.inc}, ''), false);
end;

{ like LoadClearScene, but this loads a little more complicated scene.
  It's a "welcome scene" of view3dscene. }
procedure LoadWelcomeScene;
begin
  LoadSimpleScene(LoadVRMLClassicFromString({$I welcome_scene.inc}, ''));
end;

function SavedVRMLPrecedingComment(const SourceFileName: string): string;
begin
 Result := 'VRML generated by view3dscene from ' +SourceFileName +
   ' on ' +DateTimeToAtStr(Now);
end;

{ Load model from ASceneFileName ('-' means stdin),
  do SceneChanges, and write it as VRML to stdout.
  This is simply the function to handle --write-to-vrml command-line option. }
procedure WriteToVRML(const ASceneFileName: string;
  const SceneChanges: TSceneChanges);
var Scene: TVRMLScene;
begin
 Scene := TVRMLScene.Create(nil);
 try
  Scene.Load(ASceneFileName, true);
  ChangeScene(SceneChanges, Scene);
  SaveVRMLClassic(Scene.RootNode, StdOutStream,
    SavedVRMLPrecedingComment(ASceneFileName));
 finally Scene.Free end;
end;

class procedure THelper.OpenRecent(const FileName: string);
begin
  LoadScene(FileName, [], 0.0, true);
end;

class procedure THelper.GeometryChanged(Scene: TVRMLScene;
  const SomeLocalGeometryChanged: boolean);
begin
  if SomeLocalGeometryChanged then
    { Since some PVRMLTriangle pointers are possibly completely different now,
      we have to invalidate selection. }
    Unselect else
  if SelectedItem <> nil then
  begin
    { We can keep SelectedItem, but we have to take into account that it's
      transformation possibly changed. So world coordinates of this triangle
      are different. }
    SelectedItem^.UpdateWorld;

    { Also SelectedPointWorld changed now. To apply the change, convert
      SelectedPointLocal to world coords by new trasform.
      This is the main reason why we keep SelectedPointLocal recorded. }
    try
      SelectedPointWorld := MatrixMultPoint(SelectedItem^.State.Transform,
        SelectedPointLocal);
    except
      on ETransformedResultInvalid do
        Unselect;
    end;

  end;
end;

{ make screen shots ---------------------------------------------------------- }

{ This performs all screenshot takes, as specified in ScreenShotsList.
  It is used both for batch mode screenshots (--screenshot, --screenshot-range)
  and interactive (menu items about screenshots) operation. }
procedure MakeAllScreenShots;
var
  I, J: Integer;
  OldProgressUserInterface: TProgressUserInterface;
  OldTime: TKamTime;
begin
  { Save global things that we change, to restore them later.
    This isn't needed for batch mode screenshots, but it doesn't hurt
    to be clean. }
  OldProgressUserInterface := Progress.UserInterface;
  OldTime := SceneAnimation.Time;
  try
    SceneManager.BeforeDraw;

    { For TRangeScreenShot to display progress on console
      (it cannot display progress on GL window, since this would
      mess rendered image; besides, in the future GL window may be
      hidden during rendering). }
    Progress.UserInterface := ProgressConsoleInterface;

    ScreenShotsList.BeginCapture;

    for I := 0 to ScreenShotsList.Count - 1 do
    begin
      ScreenShotsList[I].BeginCapture;
      try
        for J := 0 to ScreenShotsList[I].Count - 1 do
        begin
          SceneAnimation.ResetTime(ScreenShotsList[I].UseTime(J));
          SceneManager.Draw;
          glFlush();
          SaveScreen_NoFlush(ScreenShotsList[I].UseFileName(J), GL_BACK);
        end;
        ScreenShotsList[I].EndCapture(true);
      except
        ScreenShotsList[I].EndCapture(false);
        raise;
      end;
    end;

  finally
    Progress.UserInterface := OldProgressUserInterface;
    SceneAnimation.ResetTime(OldTime);
  end;
end;

{ menu things ------------------------------------------------------------ }

const
  Version = '3.5.2';
  DisplayProgramName = 'view3dscene';

type
  TShaderAdder = class
    ProgramNode: TNodeComposedShader;
    Added: boolean;
    procedure AddShader(Node: TVRMLNode);
  end;

procedure TShaderAdder.AddShader(Node: TVRMLNode);
var
  ShadersField: TMFNode;
begin
  ShadersField := (Node as TNodeAppearance).FdShaders;
  if not ((ShadersField.Count = 1) and (ShadersField.Items[0] = ProgramNode)) then
  begin
    ShadersField.ClearItems;
    ShadersField.AddItem(ProgramNode);
    Added := true;
  end;
end;

procedure MenuCommand(Glwin: TGLWindow; MenuItem: TMenuItem);

  procedure ChangeGravityUp;
  var Answer: string;
      NewUp: TVector3Single;
  begin
   if SceneManager.Camera is TWalkCamera then
   begin
    Answer := '';
    if MessageInputQuery(Glwin,
      'Input new camera up vector (three float values).' +nl+nl+
      'This vector will be used as new gravity upward vector. ' +
      'This vector must not be zero vector.',
      Answer, taLeft) then
    begin

     try
      NewUp := Vector3SingleFromStr(Answer);
     except
      on E: EConvertError do
      begin
       MessageOK(Glwin, 'Incorrect vector value : '+E.Message);
       Exit;
      end;
     end;

     WalkCamera.GravityUp := NewUp;
     Glw.PostRedisplay;
    end;
   end else
    MessageOK(Glwin, SOnlyInWalker);
  end;

  procedure ChangeMoveSpeed;
  var
    MoveSpeed: Single;
  begin
    if SceneManager.Camera is TWalkCamera then
    begin
      { in view3dscene, MoveHorizontalSpeed is always equal
        MoveVerticalSpeed }

      MoveSpeed := WalkCamera.MoveHorizontalSpeed;
      if MessageInputQuery(Glwin, 'New move speed:', MoveSpeed, taLeft) then
      begin
        WalkCamera.MoveHorizontalSpeed := MoveSpeed;
        WalkCamera.MoveVerticalSpeed := MoveSpeed;
        Glw.PostRedisplay;
      end;
    end else
      MessageOK(Glwin, SOnlyInWalker);
  end;


  procedure ShowAndWrite(const S: string);
  begin
    Writeln(S);
    MessageOK(Glw, S, taLeft);
  end;

  procedure ViewSceneWarnings;
  var
    S: TStringList;
  begin
    S := TStringList.Create;
    try
      S.Append(Format('Total %d warnings about current scene "%s":',
        [ SceneWarnings.Count, SceneFileName ]));
      S.Append('');
      S.AddStrings(SceneWarnings.Items);
      MessageOK(Glw, S, taLeft);
    finally FreeAndNil(S) end;
  end;

  procedure ChangePointSize;
  var
    Value: Single;
  begin
    Value := SceneAnimation.Attributes.PointSize;
    if MessageInputQuery(Glwin, 'Change point size:',
      Value, taLeft) then
      SceneAnimation.Attributes.PointSize := Value;
  end;

  procedure ChangeWireframeWidth;
  var
    Value: Single;
  begin
    Value := SceneAnimation.Attributes.WireframeWidth;
    if MessageInputQuery(Glwin, 'Change wireframe line width:',
      Value, taLeft) then
      SceneAnimation.Attributes.WireframeWidth := Value;
  end;

  procedure ChangeAnimationTimeSpeed;
  var
    S: Single;
  begin
    S := SceneAnimation.TimePlayingSpeed;
    if MessageInputQuery(Glwin,
      'Playing speed 1.0 means that 1 time unit is 1 second.' +nl+
      '0.5 makes playing animation two times slower,' +nl+
      '2.0 makes it two times faster etc.' +nl+
      nl+
      'Note that this is the "on display" playing speed.' +nl+
      nl+
      '- For pracalculated ' +
      'animations (like from Kanim or MD3 files), this means ' +
      'that internally number of precalculated animation frames ' +
      'doesn''t change. Which means that slowing this speed too much ' +
      'leads to noticeably "jagged" animations.' +nl+
      nl+
      '- For interactive animations (played and calculated from a single ' +
      'VRML / X3D file, e.g. by VRML interpolators) this is perfect, ' +
      'animation always remains smooth.' +nl+
      nl+
      'New "on display" playing speed:',
      S, taLeft) then
      SceneAnimation.TimePlayingSpeed := S;
  end;

  procedure ChangeAnimationTimeSpeedWhenLoading;
  begin
    MessageInputQuery(Glwin,
      'Playing speed 1.0 means that 1 time unit is 1 second.' +nl+
      '0.5 makes playing animation two times slower,' +nl+
      '2.0 makes it two times faster etc.' +nl+
      nl+
      'Note that this is the "on loading" playing speed. Which means ' +
      'it''s only applied when loading animation from file ' +
      '(you can use "File -> Reopen" command to apply this to currently ' +
      'loaded animation).' +nl+
      nl+
      '- For pracalculated ' +
      'animations (like from Kanim or MD3 files), changing this actually changes ' +
      'the density of precalculated animation frames. Which means that ' +
      'this is the more resource-consuming, but also better ' +
      'method of changing animation speed: even if you slow down ' +
      'this playing speed much, the animation will remain smooth.' +nl+
      nl+
      '- For interactive animations (played and calculated from a single ' +
      'VRML / X3D file, e.g. by VRML interpolators) this has no effect, ' +
      'as no frames are precalculated at loading. Use "on display" playing speed ' +
      'instead.' +nl+
      nl+
      'New "on loading" playing speed:',
      AnimationTimeSpeedWhenLoading, taLeft);
  end;

  function NodeNiceName(node: TVRMLNode): string;
  begin
   result := ''''+node.NodeName+''' (class '''+node.NodeTypeName+''')';
  end;

  procedure SelectedShowInformation;
  var
    s, TextureDescription: string;
    VCOver, TCOver, VCNotOver, TCNotOver: Cardinal;
    M1: TNodeMaterial_1;
    M2: TNodeMaterial_2;
    SelectedGeometry: TVRMLGeometryNode;
    Tex: TNodeX3DTextureNode;
  begin
    if SelectedItem = nil then
    begin
      s := 'Nothing selected.';
    end else
    begin
      SelectedGeometry := SelectedItem^.Geometry;
      s := Format(
           'Selected point %s from triangle %s (triangle id: %s).' +nl+
           nl+
           'This triangle is part of the '+
           'node named %s. Node''s bounding box is %s. ',
           [VectorToNiceStr(SelectedPointWorld),
            TriangleToNiceStr(SelectedItem^.World.Triangle),
            PointerToStr(SelectedItem),
            NodeNiceName(SelectedGeometry),
            Box3DToNiceStr(SelectedGeometry.BoundingBox(SelectedItem^.State))]);

      if (SelectedItem^.FaceCoordIndexBegin <> -1) and
         (SelectedItem^.FaceCoordIndexEnd <> -1) then
      begin
        S += Format('Face containing the selected triangle spans from %d to' +
          ' %d coordIndex entries. ',
          [ SelectedItem^.FaceCoordIndexBegin,
            SelectedItem^.FaceCoordIndexEnd ]);
      end;

      VCNotOver := SelectedGeometry.VerticesCount(SelectedItem^.State, false);
      TCNotOver := SelectedGeometry.TrianglesCount(SelectedItem^.State, false);
      VCOver := SelectedGeometry.VerticesCount(SelectedItem^.State, true);
      TCOver := SelectedGeometry.TrianglesCount(SelectedItem^.State, true);

      if (VCOver = VCNotOver) and (TCOver = TCNotOver) then
      begin
       s += Format(
              'Node has %d vertices and %d triangles '+
              '(with and without over-triangulating).',
              [VCNotOver, TCNotOver]);
      end else
      begin
       s += Format(
              'When we don''t use over-triangulating (e.g. for raytracing and '+
              'collision-detection) node has %d vertices and %d triangles. '+
              'When we use over-triangulating (e.g. for real-time rendering) '+
              'node has %d vertices and %d triangles.',
              [VCNotOver, TCNotOver, VCOver, TCOver]);
      end;

      { calculate Tex }
      Tex := SelectedItem^.State.Texture;

      { calculate TextureDescription }
      if Tex = nil then
        TextureDescription := 'none' else
      if Tex is TVRMLTextureNode then
        TextureDescription := TVRMLTextureNode(Tex).TextureDescription else
        TextureDescription := Tex.NodeTypeName;

      S += Format(nl +nl+ 'Node''s texture : %s.', [TextureDescription]);

      S += nl+ nl;
      if SelectedItem^.State.ParentShape <> nil then
      begin
        { This is VRML 2.0 node }
        M2 := SelectedItem^.State.ParentShape.Material;
        if M2 <> nil then
        begin
          S += Format(
                 'Material (VRML >= 2.0):' +nl+
                 '  name : %s' +nl+
                 '  ambientIntensity : %s' +nl+
                 '  diffuseColor : %s' +nl+
                 '  specular : %s' +nl+
                 '  shininess : %s' +nl+
                 '  transparency : %s',
                 [ M2.NodeName,
                   FloatToNiceStr(M2.FdAmbientIntensity.Value),
                   VectorToNiceStr(M2.FdDiffuseColor.Value),
                   VectorToNiceStr(M2.FdSpecularColor.Value),
                   FloatToNiceStr(M2.FdShininess.Value),
                   FloatToNiceStr(M2.FdTransparency.Value) ]);
        end else
          S += 'Material: NULL';
      end else
      begin
        M1 := SelectedItem^.State.LastNodes.Material;
        S += Format(
            'Material (VRML <= 1.0):' +nl+
            '  name : %s' +nl+
            '  ambientColor[0] : %s' +nl+
            '  diffuseColor[0] : %s' +nl+
            '  specularColor[0] : %s' +nl+
            '  shininess[0] : %s' +nl+
            '  transparency[0] : %s',
            [ M1.NodeName,
              VectorToNiceStr(M1.AmbientColor3Single(0)),
              VectorToNiceStr(M1.DiffuseColor3Single(0)),
              VectorToNiceStr(M1.SpecularColor3Single(0)),
              FloatToNiceStr(M1.Shininess(0)),
              FloatToNiceStr(M1.Transparency(0)) ]);
      end;
    end;
    ShowAndWrite(S);
  end;

  procedure SelectedShowLightsInformation;
  var
    i: integer;
    ShadowingItem: PVRMLTriangle;
    S: string;
    ActiveLights: TDynActiveLightArray;
  begin
    if SelectedItem = nil then
    begin
      s := 'Nothing selected.';
    end else
    begin
      ActiveLights := SelectedItem^.State.CurrentActiveLights;

      S := Format('Total %d lights active for selected object.',
        [ActiveLights.Count]);

      for i := 0 to ActiveLights.Count - 1 do
      begin
       s += nl+ nl + Format('Light %d (node %s) possibly affects selected point ... ',
         [ I, NodeNiceName(ActiveLights.Items[i].LightNode) ]);

       ShadowingItem := SceneOctreeCollisions.SegmentCollision(
         SelectedPointWorld, ActiveLights.Items[i].TransfLocation,
           false, SelectedItem, true, nil);

       if ShadowingItem <> nil then
       begin
        s += Format('but no, this light is blocked by triangle %s from node %s.',
          [ TriangleToNiceStr(ShadowingItem^.World.Triangle),
            NodeNiceName(ShadowingItem^.Geometry) ])
       end else
        s += 'hmm, yes ! No object blocks this light here.';
      end;
    end;

    ShowAndWrite(S);
  end;

  procedure RemoveSelectedGeometry;
  begin
    if SceneAnimation.ScenesCount > 1 then
    begin
      { We can't do this for animations, because we use
        SelectedItem^.Geometry, so this is only for the frame where
        octree is available. }
      MessageOK(Glwin, 'This function is not available when you deal with ' +
        'precalculated animations (like from Kanim or MD3 files).', taLeft);
      Exit;
    end;

    if SelectedItem = nil then
    begin
      ShowAndWrite('Nothing selected.');
    end else
    begin
      SceneAnimation.Scenes[0].NodeFreeRemovingFromAllParents(SelectedItem^.Geometry);
    end;
  end;

  procedure RemoveSelectedFace;

    function MFNonEmpty(Field: TDynLongIntArray): boolean;
    begin
      Result := (Field <> nil) and (Field.Count > 0) and
        { Single "-1" value in an MF field is the VRML 1.0 default
          weird value for normalIndex, materialIndex and textureCoordIndex
          fields. We treat it like an empty field, otherwise we wouldn't
          be able to process most VRML 1.0 files. }
        (not ((Field.Count = 1) and (Field.Items[0] = -1)));
    end;

  var
    Geometry: TVRMLGeometryNode;
    Colors, Coords, Materials, Normals, TexCoords: TDynLongIntArray;
  begin
    if SceneAnimation.ScenesCount > 1 then
    begin
      { We can't do this for animations, because we use
        SelectedItem^.Geometry, so this is only for the frame where
        octree is available. Moreover, we call
        SceneAnimation.FirstScene.ChangedFields. }
      MessageOK(Glwin, 'This function is not available when you deal with ' +
        'precalculated animations (like from Kanim or MD3 files).', taLeft);
      Exit;
    end;

    if SelectedItem = nil then
    begin
      ShowAndWrite('Nothing selected.');
      Exit;
    end;

    if (SelectedItem^.FaceCoordIndexBegin = -1) or
       (SelectedItem^.FaceCoordIndexEnd = -1) then
    begin
      ShowAndWrite('The selected triangle is not part of IndexedFaceSet node.');
      Exit;
    end;

    Geometry := SelectedItem^.Geometry;

    if Geometry is TNodeIndexedFaceSet_1 then
    begin
      Colors := nil;
      Coords := TNodeIndexedFaceSet_1(Geometry).FdCoordIndex.Items;
      Materials := TNodeIndexedFaceSet_1(Geometry).FdMaterialIndex.Items;
      Normals := TNodeIndexedFaceSet_1(Geometry).FdNormalIndex.Items;
      TexCoords := TNodeIndexedFaceSet_1(Geometry).FdTextureCoordIndex.Items;
    end else
    if Geometry is TNodeIndexedFaceSet_2 then
    begin
      Colors := TNodeIndexedFaceSet_2(Geometry).FdColorIndex.Items;
      Coords := TNodeIndexedFaceSet_2(Geometry).FdCoordIndex.Items;
      Materials := nil;
      Normals := TNodeIndexedFaceSet_2(Geometry).FdNormalIndex.Items;
      TexCoords := TNodeIndexedFaceSet_2(Geometry).FdTexCoordIndex.Items;
    end else
    if Geometry is TNodeIndexedTriangleMesh_1 then
    begin
      Colors := nil;
      Coords := TNodeIndexedTriangleMesh_1(Geometry).FdCoordIndex.Items;
      Materials := TNodeIndexedTriangleMesh_1(Geometry).FdMaterialIndex.Items;
      Normals := TNodeIndexedTriangleMesh_1(Geometry).FdNormalIndex.Items;
      TexCoords := TNodeIndexedTriangleMesh_1(Geometry).FdTextureCoordIndex.Items;
    end else
    begin
      ShowAndWrite('Internal error: cannot get the coordIndex field.');
      Exit;
    end;

    if MFNonEmpty(Colors) or MFNonEmpty(Materials) or MFNonEmpty(Normals) then
    begin
      ShowAndWrite('Removing faces from a geometry node with colorIndex, ' +
        'materialIndex or normalIndex not implemented yet.');
      Exit;
    end;

    Coords.Delete(SelectedItem^.FaceCoordIndexBegin,
      SelectedItem^.FaceCoordIndexEnd -
      SelectedItem^.FaceCoordIndexBegin + 1);

    { Texture coordinates, if not empty, have always (both in VRML 1.0
      and VRML 2.0 IndexedFaceSet nodes, and in IndexedTriangleMesh
      from Inventor) the same ordering as coordIndex.
      So we can remove equivalent texture coords in the same manner
      as we removed coords. }
    if TexCoords <> nil then
      TexCoords.Delete(SelectedItem^.FaceCoordIndexBegin,
        SelectedItem^.FaceCoordIndexEnd -
        SelectedItem^.FaceCoordIndexBegin + 1);

    SceneAnimation.FirstScene.ChangedFields(Geometry, nil);
  end;

  procedure DoProcessShadowMapsReceivers;
  begin
    if SceneAnimation.ScenesCount > 1 then
    begin
      MessageOK(Glwin, 'This function is not available when you deal with ' +
        'precalculated animations (like from Kanim or MD3 files).', taLeft);
      Exit;
    end;

    ProcessShadowMapsReceivers(SceneAnimation.FirstScene.RootNode, 256, false);

    SceneAnimation.FirstScene.ChangedAll;
  end;

  { Returns @true and sets M1 and M2 (exactly one to @nil, one to non-nil)
    if success. Produces message to user and returns @false on failure.

    Note that SelectedItem is not necessarily correct anymore. Use only
    M1 and M2 pointers after this. }
  function ChangeMaterialInit(
    out M1: TNodeMaterial_1;
    out M2: TNodeMaterial_2): boolean;
  var
    Shape: TNodeX3DShapeNode;
  begin
    if SceneAnimation.ScenesCount > 1 then
    begin
      { We can't do this for animations, because we use
        SelectedItem.State, so this is only for the frame where
        octree is available. Moreover, we call
        SceneAnimation.FirstScene.ChangedFields. }
      MessageOK(Glwin, 'This function is not available when you deal with ' +
        'precalculated animations (like from Kanim or MD3 files).', taLeft);
      Exit(false);
    end;

    if (SelectedItem = nil) then
    begin
      ShowAndWrite('Nothing selected.');
      Exit(false);
    end;

    M1 := nil;
    M2 := nil;
    Shape := SelectedItem^.State.ParentShape;
    if Shape <> nil then
    begin
      M2 := Shape.Material;
      if M2 = nil then
      begin
        if MessageYesNo(Glw, 'No material present. Add material to this node and then edit it?', taLeft) then
        begin
          { Note that this may remove old Shape.FdAppearance.Value,
            but only if Shape.Appearance = nil, indicating that
            something wrong was specified for "appearance" field.

            Similar, it may remove old Shape.Appearance.FdMaterial.Value,
            but only if Shape.Material was nil, and together
            this indicates that something incorrect was placed in "material"
            field. }
          if Shape.Appearance = nil then
          begin
            Shape.FdAppearance.Value := TNodeAppearance.Create('', '');
            Assert(Shape.Appearance <> nil);
          end;

          M2 := TNodeMaterial_2.Create('', '');
          Shape.Appearance.FdMaterial.Value := M2;
          SceneAnimation.Scenes[0].ChangedAll;
        end else
          Exit(false);
      end;
    end else
    begin
      M1 := SelectedItem^.State.LastNodes.Material;
    end;

    Result := true;
  end;

  procedure ChangeMaterialDiffuse;
  var
    M1: TNodeMaterial_1;
    M2: TNodeMaterial_2;
    Color: TVector3Single;
  begin
    if not ChangeMaterialInit(M1, M2) then Exit;

    if M2 <> nil then
      Color := M2.FdDiffuseColor.Value else
    begin
      Assert(M1 <> nil);
      if M1.FdDiffuseColor.Count > 0 then
        Color := M1.FdDiffuseColor.Items.Items[0] else
        Color := DefaultMaterialDiffuseColor;
    end;

    if Glwin.ColorDialog(Color) then
    begin
      if M2 <> nil then
      begin
        M2.FdDiffuseColor.Send(Color);
      end else
      begin
        Assert(M1 <> nil);
        M1.FdDiffuseColor.Send([Color]);
      end;
    end;
  end;

  procedure ChangeMaterialSpecular;
  var
    M1: TNodeMaterial_1;
    M2: TNodeMaterial_2;
    Color: TVector3Single;
  begin
    if not ChangeMaterialInit(M1, M2) then Exit;

    if M2 <> nil then
      Color := M2.FdSpecularColor.Value else
    begin
      Assert(M1 <> nil);
      if M1.FdSpecularColor.Count > 0 then
        Color := M1.FdSpecularColor.Items.Items[0] else
        Color := DefaultMaterialSpecularColor;
    end;

    if Glwin.ColorDialog(Color) then
    begin
      if M2 <> nil then
      begin
        M2.FdSpecularColor.Send(Color);
      end else
      begin
        Assert(M1 <> nil);
        M1.FdSpecularColor.Send([Color]);
      end;
    end;
  end;

  procedure ChangeLightModelAmbient;
  begin
    if glwin.ColorDialog(LightModelAmbient) then LightModelAmbientChanged;
  end;

  procedure SetViewpointForWholeScene(const WantedUp: Integer);
  var
    Position, Direction, Up, GravityUp: TVector3Single;
  begin
    CameraViewpointForWholeScene(SceneAnimation.BoundingBox,
      WantedUp,
      Position, Direction, Up, GravityUp);
    SetViewpointCore(Position, Direction, Up, GravityUp);
  end;

  procedure RemoveNodesWithMatchingName;
  var
    Wildcard: string;
    RemovedNumber, RemovedNumberOther: Cardinal;
    I: Integer;
  begin
    Wildcard := '';
    if MessageInputQuery(Glwin,
      'Input node name to be removed. You can use wildcards (* and ?) in ' +
      'the expression below to match many node names. The input is ' +
      'case sensitive (like all VRML).',
      Wildcard, taLeft) then
    begin
      SceneAnimation.BeforeNodesFree;

      RemovedNumber := SceneAnimation.Scenes[0].RootNode.
        RemoveChildrenWithMatchingName(Wildcard, false);
      for I := 1 to SceneAnimation.ScenesCount - 1 do
      begin
        RemovedNumberOther := SceneAnimation.Scenes[I].RootNode.
          RemoveChildrenWithMatchingName(Wildcard, false);
        Assert(RemovedNumberOther = RemovedNumber);
      end;

      SceneAnimation.ChangedAll;

      MessageOK(Glwin, Format('Removed %d node instances.', [RemovedNumber]),
        taLeft);
    end;
  end;

  procedure PrintRayhunterCommand;
  var
    S: string;
  begin
    S := Format(
       'Call rayhunter like this to render this view :' +nl+
       '  rayhunter classic %d %d %d "%s" "%s" \' +nl+
       '    --camera-pos %s \' +nl+
       '    --camera-dir %s \' +nl+
       '    --camera-up %s \' +nl+
       '    --scene-bg-color %f %f %f \' +nl,
       [ DEF_RAYTRACE_DEPTH,
         Glw.Width, Glw.Height,
         SceneFilename,
         ExtractOnlyFileName(SceneFilename) + '-rt.png',
         VectorToRawStr(WalkCamera.Position),
         VectorToRawStr(WalkCamera.Direction),
         VectorToRawStr(WalkCamera.Up),
         BGColor[0], BGColor[1], BGColor[2] ]);
    if SceneManager.PerspectiveView then
      S += Format('    --view-angle-x %f', [SceneManager.PerspectiveViewAngles[0]]) else
      S += Format('    --ortho %f %f %f %f', [
        SceneManager.OrthoViewDimensions[0],
        SceneManager.OrthoViewDimensions[1],
        SceneManager.OrthoViewDimensions[2],
        SceneManager.OrthoViewDimensions[3] ]);
    Writeln(S);
  end;

  procedure WritelnCameraSettings(Version: TVRMLCameraVersion);
  begin
    Writeln(MakeVRMLCameraStr(Version,
      WalkCamera.Position,
      WalkCamera.Direction,
      WalkCamera.Up,
      WalkCamera.GravityUp));
  end;

  procedure WriteBoundingBox(const Box: TBox3D);
  begin
    if IsEmptyBox3D(Box) then
      MessageOK(Glw, 'The bounding box is empty.', taLeft) else
    begin
      Writeln(Format(
        '# ----------------------------------------' +nl+
        '# BoundingBox %s expressed in VRML:' +nl+
        '# Version for VRML 1.0' +nl+
        'DEF BoundingBox Separator {' +nl+
        '  Translation {' +nl+
        '    translation %s' +nl+
        '  }' +nl+
        '  Cube {' +nl+
        '    width %s' +nl+
        '    height %s' +nl+
        '    depth %s' +nl+
        '  } }' +nl+
        nl+
        '# Version for VRML 2.0 / X3D' +nl+
        'DEF BoundingBox Transform {' +nl+
        '  translation %1:s' +nl+
        '  children Shape {' +nl+
        '    geometry Box {' +nl+
        '      size %2:s %3:s %4:s' +nl+
        '    } } }',
        [ Box3DToNiceStr(Box),
          VectorToRawStr(Box3DMiddle(Box)),
          FloatToRawStr(Box[1, 0] - Box[0, 0]),
          FloatToRawStr(Box[1, 1] - Box[0, 1]),
          FloatToRawStr(Box[1, 2] - Box[0, 2]) ]));
    end;
  end;

  procedure AssignGLSLShader;
  const
    VS_FileFilters =
    'All files|*|' +
    '*Vertex shader (*.vs)|*.vs';
    FS_FileFilters =
    'All files|*|' +
    '*Fragment shader (*.fs)|*.fs';
  var
    FragmentShaderUrl, VertexShaderUrl: string;
    ProgramNode: TNodeComposedShader;
    ShaderPart: TNodeShaderPart;
    ShaderAdder: TShaderAdder;
    I: Integer;
  begin
    VertexShaderUrl := '';
    if Glwin.FileDialog('Open vertex shader file', VertexShaderUrl, true,
      VS_FileFilters) then
    begin
      { We guess that FragmentShaderUrl will be in the same dir as vertex shader }
      FragmentShaderUrl := ExtractFilePath(VertexShaderUrl);
      if Glwin.FileDialog('Open fragment shader file', FragmentShaderUrl, true,
        FS_FileFilters) then
      begin
        ProgramNode := TNodeComposedShader.Create(
          { any name that has a chance to be unique }
          'view3dscene_shader_' + IntToStr(Random(1000)), '');
        ProgramNode.FdLanguage.Value := 'GLSL';

        ShaderPart := TNodeShaderPart.Create('', '');
        ProgramNode.FdParts.AddItem(ShaderPart);
        ShaderPart.FdType.Value := 'VERTEX';
        ShaderPart.FdUrl.Items.Add(VertexShaderUrl);

        ShaderPart := TNodeShaderPart.Create('', '');
        ProgramNode.FdParts.AddItem(ShaderPart);
        ShaderPart.FdType.Value := 'FRAGMENT';
        ShaderPart.FdUrl.Items.Add(FragmentShaderUrl);

        ShaderAdder := TShaderAdder.Create;
        try
          ShaderAdder.ProgramNode := ProgramNode;
          ShaderAdder.Added := false;

          SceneAnimation.BeforeNodesFree; { AddShader may remove old shader nodes }

          for I := 0 to SceneAnimation.ScenesCount - 1 do
          begin
            SceneAnimation.Scenes[I].RootNode.EnumerateNodes(TNodeAppearance,
              @ShaderAdder.AddShader, false);
          end;

          SceneAnimation.ChangedAll;

          if not ShaderAdder.Added then
          begin
            FreeAndNil(ProgramNode);
            MessageOK(Glw, 'No shaders added.' +NL+
              'Hint: this feature adds shaders to Apperance.shaders field. ' +
              'So it requires VRML >= 2.0 models with Appearance nodes present, ' +
              'otherwise nothing will be added.',
              taLeft);
          end;
        finally FreeAndNil(ShaderAdder); end;
      end;
    end;
  end;

  procedure SetFillMode(Value: TFillMode);
  begin
    FillMode := Value;
    { For fmSilhouetteBorderEdges, these things can remain as they were
      previously. }
    if FillMode <> fmSilhouetteBorderEdges then
    begin
      SceneAnimation.Attributes.WireframeEffect := FillModes[FillMode].WireframeEffect;
      SceneAnimation.Attributes.WireframeColor  := FillModes[FillMode].WireframeColor;
      SceneAnimation.Attributes.PureGeometry    := FillModes[FillMode].PureGeometry;
    end;
  end;

  procedure ScreenShotToVideo;
  var
    TimeBegin, TimeStep: TKamTime;
    FramesCount: Cardinal;
    FileNamePattern: string;
    Range: TRangeScreenShot;
  begin
    TimeBegin := SceneAnimation.Time;
    TimeStep := 0.04;
    FramesCount := 25;
    FileNamePattern := 'image%d.png';

    if MessageInputQuery(Glwin, 'Input start time for recording movie:',
      TimeBegin, taLeft) then
      if MessageInputQuery(Glwin, 'Time step between capturing movie frames:' +NL+NL+
        'Note that if you later choose to record to a single movie file, like "output.avi", then we''ll generate a movie with 25 frames per second. ' +
        'So if you want your movie to play with the same speed as animation in view3dscene then the default value, 1/25, is good.' +NL+NL+
        'Input time step between capturing movie frames:', TimeStep, taLeft) then
        if MessageInputQueryCardinal(Glwin, 'Input frames count to capture:', FramesCount, taLeft) then
          if Glwin.FileDialog('Images pattern or movie filename to save', FileNamePattern, false) then
          begin
            { ScreenShotsList should always be empty in interactive mode
              (otherwise some rendering behaves differently when
              MakingScreenShot = true) }
            Assert(ScreenShotsList.Count = 0);

            Range := TRangeScreenShot.Create;
            Range.TimeBegin := TimeBegin;
            Range.TimeStep := TimeStep;
            Range.FramesCount := FramesCount;
            Range.FileNamePattern := FileNamePattern;
            ScreenShotsList.Add(Range);

            try
              MakeAllScreenShots;
            except
              on E: EInvalidScreenShotFileName do
                MessageOk(Glwin, 'Making screenshot failed: ' +NL+NL+ E.Message, taLeft);
            end;

            ScreenShotsList.FreeContents;
          end;
  end;

  procedure PrecalculateAnimationFromVRMLEvents;
  var
    ScenesPerTime: Cardinal;
    TimeBegin, TimeEnd: Single;
    RootNode: TVRMLNode;
  const
    EqualityEpsilon = 0.0001;
  begin
    if SceneAnimation.ScenesCount <> 1 then
    begin
      MessageOK(Glwin, 'This is not possible when you already have a precalculated animation (like loaded from Kanim or MD3 file).', taLeft);
      Exit;
    end;

    TimeBegin := 0;
    TimeEnd := 10;
    ScenesPerTime := 25;

    if MessageInputQuery(Glwin, 'This will "record" an interactive animation (done by VRML events, interpolators, sensors etc.) into a non-interactive precalculated animation. This allows an animation to be played ultra-fast, although may also be memory-consuming for long ranges of time.' +nl+
         nl+
         'World BEGIN time of recording:', TimeBegin, taLeft) and
       MessageInputQuery(Glwin,
         'World END time of recording:', TimeEnd, taLeft) and
       MessageInputQueryCardinal(Glwin,
         'Scenes per second (higher values make animation smoother but also more memory-consuming):', ScenesPerTime, taLeft) then
    begin
      { Note: there's an inherent problem here since RootNode starts
        with state from current Time. This includes
        TimeDependentNodeHandler state like IsActive, etc., but also
        the rest of VRML graph (e.g. if some events change some geometry
        or materials). While LoadFromVRMLEvents takes care to call
        SceneAnimation.ResetTime, this only resets time-dependent nodes and routes
        and the like, but it cannot at the same time deactivate-and-then-activate
        time-dependent nodes in the same timestamp (so e.g. TimeSensor just
        remains active, if it was active currently and is determined to be
        active during animation, without a pair of Active.Send(false) +
        Active.Send(true)). And it cannot revert whole VRML graph state.

        This is inherent to the fact that we take current RootNode,
        not the loaded one, so it cannot really be fixed --- we would have
        to just reload RootNode from file, since we cannot keep RootNode
        copy just for this purpose.

        So I just treat it silently as non-fixable in view3dscene,
        you have to load model with ProcessEvents = initially false
        to safely do LoadFromVRMLEvents. }

      { Extract RootNode. OwnsFirstRootNode set to false, to avoid
        freeing it when current animation is closed (which is done implicitly
        at the beginning of LoadFromVRMLEvents). }
      SceneAnimation.OwnsFirstRootNode := false;
      RootNode := SceneAnimation.Scenes[0].RootNode;

      { Using LoadFromVRMLEvents will also Close the previous scene.
        Before doing this, we must always free our octrees
        (as SceneAnimation.FirstScene keeps references to our octrees). }
      SceneOctreeFree;

      { Root node will be owned by LoadFromVRMLEvents, so it will be freed }
      SceneAnimation.LoadFromVRMLEvents(RootNode, true,
        TimeBegin, TimeEnd, ScenesPerTime, EqualityEpsilon,
        'Precalculating animation');

      { Since we just destroyed RootNode, and replaced it with completely
        different scene, we have to recalculate many things.
        Recalculate octree.
        GeometryChanged takes care of invalidating SelectedItem and such. }
      SceneOctreeCreate;
      THelper.GeometryChanged(nil, true);
      THelper.ViewpointsChanged(SceneAnimation.FirstScene);
    end;
  end;

  procedure SelectedShapeOctreeStat;
  var
    SI: TVRMLShapeTreeIterator;
    Shape: TVRMLShape;
  begin
    if SelectedItem = nil then
    begin
      MessageOk(Glwin, 'Nothing selected.', taLeft);
    end else
    begin
      Shape := nil;
      { TODO: 1. this will be wrong when the same geometry node and state
        will be within one TVRMLShape 2. TVRMLTriangle should just
        have a link to Shape. }

      SI := TVRMLShapeTreeIterator.Create(SceneAnimation.FirstScene.Shapes, false);
      try
        while SI.GetNext do
        begin
          Shape := SI.Current;
          if (Shape.Geometry = SelectedItem^.Geometry) and
             (Shape.State = SelectedItem^.State) then
            Break else
            Shape := nil;
        end;
      finally FreeAndNil(SI) end;

      if Shape = nil then
        MessageOk(Glwin, 'Shape not found --- hmmm, this should not happen, report a bug.', taLeft) else
      if Shape.OctreeTriangles = nil then
        MessageOk(Glwin, 'No collision octree was initialized for this shape.', taLeft) else
      begin
        Writeln(Shape.OctreeTriangles.Statistics);
      end;
    end;
  end;

  const
    DefaultCubeMapSize = 256;

  procedure ScreenShotToCubeMap;
  var
    Side: TCubeMapSide;
    CubeMapImg: TCubeMapImages;
    FileNamePattern: string;
    Orientation: char;
    Size: Cardinal;
  begin
    Orientation := MessageChar(Glwin,
      'This function will save six separate image files that show cube map environment around you.' + NL +
      NL +
      'In a moment you will be asked to choose directory and base filename for saving these images, right now you have to decide how the cube map faces will be oriented and named. ("Names" of cube map faces will be placed instead of "%s" in image file pattern.)' + NL +
      NL +
      '[B] : VRML/X3D Background orientation (left/right/...)' + NL +
      '[O] : OpenGL orientation (positive/negative x/y/z)' + NL +
      '[D] : DirectX (and DDS) orientation (positive/negative x/y/z, in left-handed coord system)' + NL +
      NL +
      '[Escape] Cancel',
      ['b', 'o', 'd', CharEscape],
      'Press [B], [O], [D] or [Escape]',
      taLeft, true);

    if Orientation <> CharEscape then
    begin
      if SceneFileName <> '' then
        FileNamePattern := ExtractOnlyFileName(SceneFileName) + '_cubemap_%s.png' else
        FileNamePattern := 'view3dscene_cubemap_%s.png';

      if Glwin.FileDialog('Image name template to save', FileNamePattern, false) then
      begin
        Size := DefaultCubeMapSize;

        if MessageInputQueryCardinal(Glwin, 'Size of cube map images', Size, taLeft) then
        begin
          for Side := Low(Side) to High(Side) do
            CubeMapImg[Side] := TRGBImage.Create(Size, Size);

          GLCaptureCubeMapImages(CubeMapImg, WalkCamera.Position,
            @SceneManager.RenderFromViewEverything,
            SceneManager.WalkProjectionNear, SceneManager.WalkProjectionFar,
            true, 0, 0);
          glViewport(0, 0, Glwin.Width, Glwin.Height);

          case Orientation of
            'b':
              begin
                CubeMapImg[csPositiveX].Rotate(2);
                CubeMapImg[csNegativeX].Rotate(2);
                CubeMapImg[csPositiveZ].Rotate(2);
                CubeMapImg[csNegativeZ].Rotate(2);
                SaveImage(CubeMapImg[csPositiveX], Format(FileNamePattern, ['right']));
                SaveImage(CubeMapImg[csNegativeX], Format(FileNamePattern, ['left']));
                SaveImage(CubeMapImg[csPositiveY], Format(FileNamePattern, ['top']));
                SaveImage(CubeMapImg[csNegativeY], Format(FileNamePattern, ['bottom']));
                SaveImage(CubeMapImg[csPositiveZ], Format(FileNamePattern, ['back']));
                SaveImage(CubeMapImg[csNegativeZ], Format(FileNamePattern, ['front']));
              end;
            'o':
              begin
                { This is the most natural Orientation,
                  our csXxx names match OpenGL names and orientation. }
                SaveImage(CubeMapImg[csPositiveX], Format(FileNamePattern, ['positive_x']));
                SaveImage(CubeMapImg[csNegativeX], Format(FileNamePattern, ['negative_x']));
                SaveImage(CubeMapImg[csPositiveY], Format(FileNamePattern, ['positive_y']));
                SaveImage(CubeMapImg[csNegativeY], Format(FileNamePattern, ['negative_y']));
                SaveImage(CubeMapImg[csPositiveZ], Format(FileNamePattern, ['positive_z']));
                SaveImage(CubeMapImg[csNegativeZ], Format(FileNamePattern, ['negative_z']));
              end;
            'd':
              begin
                { Swap positive/negative y, since DirectX is left-handed. }
                SaveImage(CubeMapImg[csPositiveX], Format(FileNamePattern, ['positive_x']));
                SaveImage(CubeMapImg[csNegativeX], Format(FileNamePattern, ['negative_x']));
                SaveImage(CubeMapImg[csNegativeY], Format(FileNamePattern, ['positive_y']));
                SaveImage(CubeMapImg[csPositiveY], Format(FileNamePattern, ['negative_y']));
                SaveImage(CubeMapImg[csPositiveZ], Format(FileNamePattern, ['positive_z']));
                SaveImage(CubeMapImg[csNegativeZ], Format(FileNamePattern, ['negative_z']));
              end;
            else EInternalError.Create('orient?');
          end;

          for Side := Low(Side) to High(Side) do
            FreeAndNil(CubeMapImg[Side]);
        end;
      end;
    end;
  end;

  procedure ScreenShotToCubeMapDDS;
  var
    DDS: TDDSImage;
    FileName: string;
    Size: Cardinal;
  begin
    if SceneFileName <> '' then
      FileName := ExtractOnlyFileName(SceneFileName) + '_cubemap.dds' else
      FileName := 'view3dscene_cubemap.dds';

    if Glwin.FileDialog('Save image to file', FileName, false) then
    begin
      Size := DefaultCubeMapSize;

      if MessageInputQueryCardinal(Glwin, 'Size of cube map images', Size, taLeft) then
      begin
        DDS := GLCaptureCubeMapDDS(Size, WalkCamera.Position,
          @SceneManager.RenderFromViewEverything,
          SceneManager.WalkProjectionNear, SceneManager.WalkProjectionFar,
          true, 0, 0);
        try
          glViewport(0, 0, Glwin.Width, Glwin.Height);
          DDS.SaveToFile(FileName);
        finally FreeAndNil(DDS) end;
      end;
    end;
  end;

  procedure ScreenShotDepthToImage;

    procedure DoSave(const FileName: string);
    var
      PackData: TPackNotAlignedData;
      Image: TGrayscaleImage;
    begin
      { Just like TGLWindow.SaveScreen, we have to force redisplay now
        (otherwise we could be left here with random buffer contents from
        other window obscuring us, or we could have depth buffer from
        other drawing routine (like "frozen screen" drawn under FileDialog). }
      Glwin.EventBeforeDraw;
      Glwin.EventDraw;

      Image := TGrayscaleImage.Create(Glwin.Width, Glwin.Height);
      try
        BeforePackImage(PackData, Image);
        try
          glReadPixels(0, 0, Glwin.Width, Glwin.Height, GL_DEPTH_COMPONENT,
            ImageGLType(Image), Image.RawPixels);
        finally AfterPackImage(PackData, Image) end;

        SaveImage(Image, FileName);
      finally FreeAndNil(Image) end;
    end;

  var
    FileName: string;
  begin
    if SceneFileName <> '' then
      FileName := ExtractOnlyFileName(SceneFileName) + '_depth_%d.png' else
      FileName := 'view3dscene_depth_%d.png';
    FileName := FileNameAutoInc(FileName);

    if Glwin.FileDialog('Save depth to a file', FileName, false,
      SaveImage_FileFilters) then
      DoSave(FileName);
  end;

  procedure Raytrace;
  var
    Pos, Dir, Up: TVector3Single;
  begin
    SceneManager.Camera.GetCameraVectors(Pos, Dir, Up);
    RaytraceToWin(Glwin, SceneAnimation.FirstScene,
      HeadLight, SceneHeadLight,
      Pos, Dir, Up,
      SceneManager.PerspectiveView, SceneManager.PerspectiveViewAngles,
      SceneManager.OrthoViewDimensions, BGColor,
      SceneAnimation.FirstScene.FogNode,
      SceneAnimation.FirstScene.FogDistanceScaling);
  end;

  procedure MergeCloseVertexes;
  var
    Coord: TMFVec3f;
    MergeDistance: Single;
    MergedCount: Cardinal;
  begin
    if SceneAnimation.ScenesCount > 1 then
    begin
      { We can't do this for animations, because we use
        SelectedItem^.Geometry, so this is only for the frame where
        octree is available. }
      MessageOK(Glwin, 'This function is not available when you deal with ' +
        'precalculated animations (like from Kanim or MD3 files).', taLeft);
      Exit;
    end;

    if SelectedItem = nil then
    begin
      MessageOk(Glwin, 'Nothing selected.', taLeft);
      Exit;
    end;

    if not SelectedItem^.Geometry.Coord(SelectedItem^.State, Coord) then
    begin
      MessageOK(Glwin, 'Selected geometry node doesn''t have a coordinate field. Nothing to merge.', taLeft);
      Exit;
    end;

    if Coord = nil then
    begin
      MessageOK(Glwin, 'Selected geometry node''s has an empty coordinate field. Nothing to merge.', taLeft);
      Exit;
    end;

    MergeDistance := 0.01;
    if MessageInputQuery(Glwin, 'Input merge distance. Vertexes closer than this will be set to be exactly equal.',
      MergeDistance, taLeft, '0.01') then
    begin
      MergedCount := Coord.Items.MergeCloseVertexes(MergeDistance);
      if MergedCount <> 0 then
        Coord.Changed;
      MessageOK(Glwin, Format('Merged %d vertexes.', [MergedCount]), taLeft);
    end;
  end;

var
  S, ProposedScreenShotName: string;
begin
 case MenuItem.IntData of
  10: begin
       s := ExtractFilePath(SceneFilename);
       if glwin.FileDialog('Open file', s, true,
         LoadVRMLSequence_FileFilters) then
         LoadScene(s, [], 0.0, true);
      end;

  12: Glw.Close;

  15: begin
        { When reopening, then JumpToInitialViewpoint parameter is false.
          In fact, this was the purpose of this JumpToInitialViewpoint
          parameter: to set it to false when reopening, as this makes
          reopening more useful. }
        LoadScene(SceneFileName, [], 0.0, false);
      end;

  20: begin
        if SceneAnimation.ScenesCount > 1 then
          MessageOK(Glwin, 'Warning: this is a precalculated animation (like from Kanim or MD3 file). Saving it as VRML will only save it''s first frame.',
            taLeft);

        { TODO: this filename gen is stupid, it leads to names like
          _2, _2_2, _2_2_2... while it should lead to _2, _3, _4 etc.... }
        if AnsiSameText(ExtractFileExt(SceneFilename), '.wrl') then
          s := AppendToFileName(SceneFilename, '_2') else
          s := ChangeFileExt(SceneFilename, '.wrl');
        if glwin.FileDialog('Save as VRML file', s, false,
          SaveVRMLClassic_FileFilters) then
        try
          SaveVRMLClassic(SceneAnimation.FirstScene.RootNode, s,
            SavedVRMLPrecedingComment(SceneFileName));
        except
          on E: Exception do
          begin
            MessageOK(glw, 'Error while saving scene to "' +S+ '": ' +
              E.Message, taLeft);
          end;
        end;
      end;

  21: ViewSceneWarnings;

  31: ChangeSceneAnimation([scNoNormals], SceneAnimation);
  32: ChangeSceneAnimation([scNoSolidObjects], SceneAnimation);
  33: ChangeSceneAnimation([scNoConvexFaces], SceneAnimation);

  34: RemoveNodesWithMatchingName;
  35: DoProcessShadowMapsReceivers;
  36: RemoveSelectedGeometry;
  37: RemoveSelectedFace;

  41: AssignGLSLShader;

  { Before all calls to SetViewpointCore below, we don't really have to
    swith to cmWalk. But user usually wants to switch to cmWalk ---
    in cmExamine viewpoint result is not visible at all. }
  51: begin
        SetCameraMode(SceneManager, cmWalk);
        SetViewpointCore(DefaultVRMLCameraPosition[1],
                         DefaultVRMLCameraDirection,
                         DefaultVRMLCameraUp,
                         DefaultVRMLGravityUp);
      end;
  52: begin
        SetCameraMode(SceneManager, cmWalk);
        SetViewpointCore(DefaultVRMLCameraPosition[2],
                         DefaultVRMLCameraDirection,
                         DefaultVRMLCameraUp,
                         DefaultVRMLGravityUp);
      end;
  53: begin
        SetCameraMode(SceneManager, cmWalk);
        SetViewpointForWholeScene(1);
      end;
  54: begin
        SetCameraMode(SceneManager, cmWalk);
        SetViewpointForWholeScene(2);
      end;

  82: ShowBBox := not ShowBBox;
  83: with SceneAnimation do Attributes.SmoothShading := not Attributes.SmoothShading;
  84: if glwin.ColorDialog(BGColor) then BGColorChanged;
  85: with SceneAnimation do Attributes.UseFog := not Attributes.UseFog;
  86: with SceneAnimation do Attributes.Blending := not Attributes.Blending;
  87: with SceneAnimation do Attributes.GLSLShaders := not Attributes.GLSLShaders;
  88: with SceneAnimation do Attributes.UseOcclusionQuery := not Attributes.UseOcclusionQuery;
  89: with SceneAnimation do Attributes.BlendingSort := not Attributes.BlendingSort;
  90: with SceneAnimation do Attributes.UseHierarchicalOcclusionQuery := not Attributes.UseHierarchicalOcclusionQuery;
  891: with SceneAnimation do Attributes.DebugHierOcclusionQueryResults := not Attributes.DebugHierOcclusionQueryResults;

  91: with SceneAnimation.Attributes do Lighting := not Lighting;
  92: HeadLight := not HeadLight;
  93: with SceneAnimation.Attributes do UseSceneLights := not UseSceneLights;
  94: with SceneAnimation do Attributes.EnableTextures := not Attributes.EnableTextures;
  95: ChangeLightModelAmbient;
  96: ShowFrustum := not ShowFrustum;
  180: ShowFrustumAlwaysVisible := not ShowFrustumAlwaysVisible;

  97: OctreeTrianglesDisplay.DoMenuToggleWhole;
  98: OctreeTrianglesDisplay.DoMenuIncDepth;
  99: OctreeTrianglesDisplay.DoMenuDecDepth;

  190: OctreeVisibleShapesDisplay.DoMenuToggleWhole;
  191: OctreeVisibleShapesDisplay.DoMenuIncDepth;
  192: OctreeVisibleShapesDisplay.DoMenuDecDepth;

  195: OctreeCollidableShapesDisplay.DoMenuToggleWhole;
  196: OctreeCollidableShapesDisplay.DoMenuIncDepth;
  197: OctreeCollidableShapesDisplay.DoMenuDecDepth;

  100: SelectedShapeOctreeStat;
  101: if SceneOctreeCollisions <> nil then
         Writeln(SceneOctreeCollisions.Statistics) else
         MessageOk(Glwin, SOnlyWhenOctreeAvailable, taLeft);
  103: if SceneOctreeRendering <> nil then
         Writeln(SceneOctreeRendering.Statistics) else
         MessageOk(Glwin, SOnlyWhenOctreeAvailable, taLeft);
  102: SceneAnimation.WritelnInfoNodes;

  105: PrintRayhunterCommand;

  106: WritelnCameraSettings(1);
  107: WritelnCameraSettings(2);

  108: Writeln(
         'Current Walk navigation frustum planes :' +nl+
         '((A, B, C, D) means a plane given by equation A*x + B*y + C*z + D = 0.)' +nl+
         '  Left   : ' + VectorToRawStr(WalkCamera.Frustum.Planes[fpLeft]) +nl+
         '  Right  : ' + VectorToRawStr(WalkCamera.Frustum.Planes[fpRight]) +nl+
         '  Bottom : ' + VectorToRawStr(WalkCamera.Frustum.Planes[fpBottom]) +nl+
         '  Top    : ' + VectorToRawStr(WalkCamera.Frustum.Planes[fpTop]) +nl+
         '  Near   : ' + VectorToRawStr(WalkCamera.Frustum.Planes[fpNear]) +nl+
         '  Far    : ' + VectorToRawStr(WalkCamera.Frustum.Planes[fpFar]));

  109: WriteBoundingBox(SceneAnimation.BoundingBox);
  110: WriteBoundingBox(SceneAnimation.CurrentScene.BoundingBox);

  111: ChangeCameraMode(SceneManager, +1);

  121: begin
         ShowAndWrite(
           'Scene "' + SceneFilename + '" information:' + NL + NL +
           SceneAnimation.Info(true, true, false));
       end;
  122: ShowStatus := not ShowStatus;
  123: SetCollisionCheck(not SceneAnimation.Collides, false);
  124: ChangeGravityUp;
  125: Raytrace;
  126: Glw.SwapFullScreen;
  127: begin
         if SceneFileName <> '' then
           ProposedScreenShotName := ExtractOnlyFileName(SceneFileName) + '_%d.png' else
           ProposedScreenShotName := 'view3dscene_screen_%d.png';
         Glwin.SaveScreenDialog(FileNameAutoInc(ProposedScreenShotName));
       end;
  128: begin
         WalkCamera.MouseLook := not WalkCamera.MouseLook;

         if WalkCamera.MouseLook then
         begin
           WalkCamera.Input_LeftStrafe.AssignFromDefault(WalkCamera.Input_LeftRot);
           WalkCamera.Input_RightStrafe.AssignFromDefault(WalkCamera.Input_RightRot);
           WalkCamera.Input_LeftRot.AssignFromDefault(WalkCamera.Input_LeftStrafe);
           WalkCamera.Input_RightRot.AssignFromDefault(WalkCamera.Input_RightStrafe);
         end else
         begin
           WalkCamera.Input_LeftStrafe.MakeDefault;
           WalkCamera.Input_RightStrafe.MakeDefault;
           WalkCamera.Input_LeftRot.MakeDefault;
           WalkCamera.Input_RightRot.MakeDefault;
         end;
       end;

  129: begin
         ShowAndWrite(SceneAnimation.Info(false, false, true));
         SceneAnimation.FreeResources([frManifoldAndBorderEdges]);
       end;

  131: begin
         ShowAndWrite(
           'view3dscene: VRML / X3D browser and full-featured viewer of other 3D models.' +nl+
           'Formats: X3D, VRML 1.0 and 2.0 (aka VRML 97), 3DS, MD3, Wavefront OBJ, Collada.' + NL +
           'Version ' + Version + '.' + NL +
           'By Michalis Kamburelis.' + NL +
           NL +
           '[http://vrmlengine.sourceforge.net/view3dscene.php]' + NL +
           NL +
           'Compiled with ' + SCompilerDescription +'.');
       end;

  171: SelectedShowInformation;
  172: SelectedShowLightsInformation;
  173: ShowAndWrite(GLInformationString);

  182: ChangePointSize;

  201: WalkCamera.Gravity := not WalkCamera.Gravity;
  202: WalkCamera.PreferGravityUpForRotations := not WalkCamera.PreferGravityUpForRotations;
  203: WalkCamera.PreferGravityUpForMoving := not WalkCamera.PreferGravityUpForMoving;
  205: ChangeMoveSpeed;
  210: WalkCamera.IgnoreAllInputs := not WalkCamera.IgnoreAllInputs;

  220: begin
         AnimationTimePlaying := not AnimationTimePlaying;
         SceneAnimation.TimePlaying := AnimationTimePlaying and ProcessEventsWanted;
       end;
  221: SceneAnimation.ResetTimeAtLoad(true);
  222: ChangeAnimationTimeSpeed;
  223: ChangeAnimationTimeSpeedWhenLoading;

  224: begin
         ProcessEventsWanted := not ProcessEventsWanted;
         SceneAnimation.TimePlaying := AnimationTimePlaying and ProcessEventsWanted;
         UpdateProcessEvents;
       end;

  225: PrecalculateAnimationFromVRMLEvents;

  300..399:
    begin
      { We could just bind given viewpoint, without swithing to cmWalk.
        But user usually wants to switch to cmWalk --- in cmExamine
        current viewpoint is not visible at all. }
      SetCameraMode(SceneManager, cmWalk);
      ViewpointsList[MenuItem.IntData - 300].EventSet_Bind.
        Send(true, SceneAnimation.FirstScene.Time);
      { Sending set_bind = true works fine if it's not current viewpoint,
        otherwise nothing happens... So just call UpdateViewpointNode
        explicitly, to really reset on the given viewpoint. }
      UpdateViewpointNode;
    end;

  400..419: SceneAnimation.Attributes.BlendingSourceFactor :=
    BlendingFactors[MenuItem.IntData - 400].Value;
  420..439: SceneAnimation.Attributes.BlendingDestinationFactor :=
    BlendingFactors[MenuItem.IntData - 420].Value;

  500..519:
    begin
      SetFillMode(MenuItem.IntData - 500);
      { appropriate Checked will be set automatically }
    end;
  520:
    begin
      SetFillMode((FillMode + 1) mod (High(FillMode) + 1));
      FillModesMenu[FillMode].Checked := true;
    end;

  530: ChangeWireframeWidth;

  540: ScreenShotToVideo;
  550: ScreenShotToCubeMap;
  555: ScreenShotToCubeMapDDS;
  560: ScreenShotDepthToImage;

  600..649: AntiAliasing := MenuItem.IntData - 600;

  710: ChangeMaterialDiffuse;
  720: ChangeMaterialSpecular;
  730: MergeCloseVertexes;

  740: ShadowsPossibleWanted := not ShadowsPossibleWanted;
  750: ShadowsOn := not ShadowsOn;
  760: DrawShadowVolumes := not DrawShadowVolumes;
  765: with SceneAnimation.Attributes do VarianceShadowMaps := not VarianceShadowMaps;

  770: InitialShowBBox := not InitialShowBBox;
  771: InitialShowStatus := not InitialShowStatus;

  1000..1099: SetColorModulatorType(
    TColorModulatorType(MenuItem.IntData-1000), SceneAnimation);
  1100..1199: SetTextureMinFilter(
    TTextureMinFilter  (MenuItem.IntData-1100), SceneAnimation);
  1200..1299: SetTextureMagFilter(
    TTextureMagFilter  (MenuItem.IntData-1200), SceneAnimation);
  1300..1399: SetCameraMode(SceneManager,
    TCameraMode(     MenuItem.IntData-1300));
  1400..1499: SceneAnimation.Attributes.BumpMappingMaximum :=
    TBumpMappingMethod( MenuItem.IntData-1400);
  1500..1599:
    begin
      Optimization := TGLRendererOptimization(MenuItem.IntData-1500);
      { This is not needed, as radio items for optimization have AutoCheckedToggle
        OptimizationMenu[Optimization].Checked := true;
      }
      SceneAnimation.Optimization := Optimization;
    end;
  1600..1699: SetTextureModeRGB(
    TTextureMode(MenuItem.IntData-1600), SceneAnimation);
  else raise EInternalError.Create('not impl menu item');
 end;

 { This may be called when headlight on / off state changes,
   so prVisibleSceneNonGeometry is possible.
   For safety, pass also prVisibleSceneGeometry now. }
 SceneAnimation.CurrentScene.VisibleChangeHere(
   [vcVisibleGeometry, vcVisibleNonGeometry]);
end;

function CreateMainMenu: TMenu;

  procedure AppendColorModulators(M: TMenu);
  begin
    M.AppendRadioGroup(ColorModulatorNames, 1000, Ord(ColorModulatorType), true);
  end;

  procedure AppendNavigationTypes(M: TMenu);
  var
    Mode: TCameraMode;
    Group: TMenuItemRadioGroup;
  begin
    Group := M.AppendRadioGroup(CameraNames, 1300, Ord(CameraMode), true);
    for Mode := Low(Mode) to High(Mode) do
      CameraRadios[Mode] := Group.Items[Ord(Mode)];
  end;

  procedure AppendBlendingFactors(M: TMenu; Source: boolean;
    BaseIntData: Cardinal);
  var
    Radio: TMenuItemRadio;
    RadioGroup: TMenuItemRadioGroup;
    I: Cardinal;
    Caption: string;
    IsDefault: boolean;
  begin
    RadioGroup := nil;

    for I := Low(BlendingFactors) to High(BlendingFactors) do
      if (Source and BlendingFactors[I].ForSource) or
         ((not Source) and BlendingFactors[I].ForDestination) then
      begin
        if Source then
          IsDefault := BlendingFactors[I].Value = DefaultBlendingSourceFactor else
          IsDefault := BlendingFactors[I].Value = V3DDefaultBlendingDestinationFactor;
        Caption := SQuoteMenuEntryCaption(BlendingFactors[I].Name);
        if IsDefault then
          Caption += ' (default)';
        Radio := TMenuItemRadio.Create(Caption, BaseIntData + I, IsDefault, true);
        if RadioGroup = nil then
          RadioGroup := Radio.Group else
          Radio.Group := RadioGroup;
        M.Append(Radio);
      end;
  end;

  procedure AppendBumpMappingMethods(M: TMenu);
  var
    BM: TBumpMappingMethod;
    Radio: TMenuItemRadio;
    RadioGroup: TMenuItemRadioGroup;
  begin
    RadioGroup := nil;
    for BM := Low(BM) to High(BM) do
    begin
      Radio := TMenuItemRadio.Create(
        SQuoteMenuEntryCaption(BumpMappingMethodNames[BM]),
        Ord(BM) + 1400, BM = DefaultBumpMappingMaximum, true);
      if RadioGroup = nil then
        RadioGroup := Radio.Group else
        Radio.Group := RadioGroup;
      M.Append(Radio);
    end;
  end;

var
  M, M2, M3: TMenu;
  NextRecentMenuItem: TMenuEntry;
begin
 Result := TMenu.Create('Main menu');
 M := TMenu.Create('_File');
   M.Append(TMenuItem.Create('_Open ...',         10, CtrlO));
   MenuReopen := TMenuItem.Create('_Reopen',      15);
   MenuReopen.Enabled := false;
   M.Append(MenuReopen);
   M.Append(TMenuItem.Create('_Save as VRML ...', 20));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('View _Warnings About Current Scene', 21));
   M.Append(TMenuSeparator.Create);
   M2 := TMenu.Create('_Preferences');
     M3 := TMenu.Create('_Anti Aliasing (Restart view3dscene to Apply)');
       MenuAppendAntiAliasing(M3, 600);
       M2.Append(M3);
     M3 := TMenu.Create('_Rendering optimization');
       MenuAppendOptimization(M3, 1500);
       M2.Append(M3);
     M2.Append(TMenuItemChecked.Create('_Shadows Possible (Restart view3dscene to Apply)',
       740, ShadowsPossibleWanted, true));
     M2.Append(TMenuItemChecked.Create('Show Bounding Box at Start', 770,
       InitialShowBBox, true));
     M2.Append(TMenuItemChecked.Create('Show Status Text at Start', 771,
       InitialShowStatus, true));
     M.Append(M2);
   NextRecentMenuItem := TMenuSeparator.Create;
   M.Append(NextRecentMenuItem);
   RecentMenu.NextMenuItem := NextRecentMenuItem;
   M.Append(TMenuItem.Create('_Exit',             12, CtrlW));
   Result.Append(M);
 M := TMenu.Create('_View');
   M2 := TMenu.Create('_Fill Mode');
     MenuAppendFillModes(M2, 500);
     M2.Append(TMenuSeparator.Create);
     M2.Append(TMenuItem.Create('Next _Fill Mode', 520, CtrlF));
     M2.Append(TMenuSeparator.Create);
     M2.Append(TMenuItem.Create('Set Wireframe Line Width ...', 530));
     M.Append(M2);
   M.Append(TMenuItemChecked.Create('Show _Bounding Box',      82, CtrlB,
     ShowBBox, true));
   M.Append(TMenuItemChecked.Create('_Smooth Shading',         83,
     SceneAnimation.Attributes.SmoothShading, true));
   M.Append(TMenuItem.Create('Change Background Color ...',    84));
   M.Append(TMenuItemChecked.Create('_Fog',                    85,
     SceneAnimation.Attributes.UseFog, true));
   M.Append(TMenuItemChecked.Create('_GLSL shaders',          87,
     SceneAnimation.Attributes.GLSLShaders, true));
   M2 := TMenu.Create('Bump mapping');
     AppendBumpMappingMethods(M2);
     M.Append(M2);
   MenuShadowsMenu := TMenu.Create('Shadow Volumes');
     MenuShadowsMenu.Enabled := ShadowsPossibleCurrently;
     MenuShadowsMenu.Append(TMenuItemChecked.Create('Use shadow volumes (requires light with kambiShadowsMain)', 750,
       ShadowsOn, true));
     MenuShadowsMenu.Append(TMenuItemChecked.Create('Draw shadow volumes', 760,
       DrawShadowVolumes, true));
     M.Append(MenuShadowsMenu);
   M.Append(TMenuItemChecked.Create('Variance Shadow Maps (nicer)', 765,
     SceneAnimation.Attributes.VarianceShadowMaps, true));
   M2 := TMenu.Create('Change Scene Colors');
     AppendColorModulators(M2);
     M.Append(M2);
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItemChecked.Create(
     '_Lighting (GL__LIGHTING enabled)',         91, CtrlL,
     SceneAnimation.Attributes.Lighting, true));
   MenuHeadlight := TMenuItemChecked.Create('_Head Light', 92, CtrlH,
     Headlight, true);
   M.Append(MenuHeadlight);
   M.Append(TMenuItemChecked.Create('Use Scene Lights',    93,
     SceneAnimation.Attributes.UseSceneLights, true));
   M.Append(TMenuItem.Create('Light Global Ambient Color ...',  95));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItemChecked.Create('_Textures',           94, CtrlT,
     SceneAnimation.Attributes.EnableTextures, true));
   M2 := TMenu.Create('Texture Minification Method');
     MenuAppendTextureMinFilters(M2, 1100);
     M.Append(M2);
   M2 := TMenu.Create('Texture Magnification Method');
     MenuAppendTextureMagFilters(M2, 1200);
     M.Append(M2);
   M2 := TMenu.Create('RGB Textures Color Mode');
     MenuAppendTextureModeRGB(M2, 1600);
     M.Append(M2);
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItemChecked.Create('Blending',                86,
     SceneAnimation.Attributes.Blending, true));
   M2 := TMenu.Create('Blending Source Factor');
     AppendBlendingFactors(M2, true, 400);
     M.Append(M2);
   M2 := TMenu.Create('Blending Destination Factor');
     AppendBlendingFactors(M2, false, 420);
     M.Append(M2);
   M.Append(TMenuItemChecked.Create('Sort transparent shapes', 89,
     SceneAnimation.Attributes.BlendingSort, true));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItemChecked.Create('_Use Occlusion Query', 88,
     SceneAnimation.Attributes.UseOcclusionQuery, true));
   M.Append(TMenuItemChecked.Create('Use Hierarchical Occlusion Query', 90,
     SceneAnimation.Attributes.UseHierarchicalOcclusionQuery, true));
   M.Append(TMenuItemChecked.Create('Debug Last Hierarchical Occlusion Query Results', 891,
     SceneAnimation.Attributes.DebugHierOcclusionQueryResults, true));
   M2 := TMenu.Create('Frustum visualization');
     M2.Append(TMenuItemChecked.Create('Show Walk frustum in Examine mode', 96,
       ShowFrustum, true));
     M2.Append(TMenuItemChecked.Create('When Showing Frustum, ' +
       'Show it Over All Other Objects (no depth test)', 180,
       ShowFrustumAlwaysVisible, true));
     M.Append(M2);
   M2 := TMenu.Create('Octree visualization');
     OctreeTrianglesDisplay.MenuWhole :=
       TMenuItemChecked.Create('Show Whole Collisions (Triangle) Octrees',
       97, OctreeTrianglesDisplay.Whole, true);
     M2.Append(OctreeTrianglesDisplay.MenuWhole);
     M2.Append(TMenuItem.Create('Show _Upper Level of Collisions (Triangle) Octrees', 98, CtrlU));
     M2.Append(TMenuItem.Create('Show _Lower Level of Collisions (Triangle) Octrees', 99, CtrlD));
     M2.Append(TMenuSeparator.Create);
     OctreeVisibleShapesDisplay.MenuWhole :=
       TMenuItemChecked.Create('Show Whole Visible Shapes Octree',
       190, OctreeVisibleShapesDisplay.Whole, true);
     M2.Append(OctreeVisibleShapesDisplay.MenuWhole);
     M2.Append(TMenuItem.Create('Show _Upper Level of Visible Shapes Octree', 191));
     M2.Append(TMenuItem.Create('Show _Lower Level of Visible Shapes Octree', 192));
     M2.Append(TMenuSeparator.Create);
     OctreeCollidableShapesDisplay.MenuWhole :=
       TMenuItemChecked.Create('Show Whole Collidable Shapes Octree',
       195, OctreeCollidableShapesDisplay.Whole, true);
     M2.Append(OctreeCollidableShapesDisplay.MenuWhole);
     M2.Append(TMenuItem.Create('Show _Upper Level of Collidable Shapes Octree', 196));
     M2.Append(TMenuItem.Create('Show _Lower Level of Collidable Shapes Octree', 197));
     M.Append(M2);
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Set Point Size ...', 182));
   Result.Append(M);
 M := TMenu.Create('_Navigation');
   ViewpointsList.MenuJumpToViewpoint := TMenu.Create('Jump to Viewpoint');
     ViewpointsList.MakeMenuJumpToViewpoint;
     M.Append(ViewpointsList.MenuJumpToViewpoint);
   M2 := TMenu.Create('Navigation Mode');
     AppendNavigationTypes(M2);
     M2.Append(TMenuSeparator.Create);
     M2.Append(TMenuItem.Create('Switch to Next', 111, CtrlN));
     M.Append(M2);
   M2 := TMenu.Create('Walk mode Settings');
     M2.Append(TMenuItemChecked.Create(
       '_Use Mouse Look',                       128, CtrlM,
         WalkCamera.MouseLook, true));
     MenuGravity := TMenuItemChecked.Create(
       '_Gravity',                              201, CtrlG,
       WalkCamera.Gravity, true);
     M2.Append(MenuGravity);
     MenuPreferGravityUpForRotations := TMenuItemChecked.Create(
       'Rotate with Respect to Stable (Gravity) Camera Up',      202,
       WalkCamera.PreferGravityUpForRotations, true);
     M2.Append(MenuPreferGravityUpForRotations);
     MenuPreferGravityUpForMoving := TMenuItemChecked.Create(
       'Move with Respect to Stable (Gravity) Camera Up',          203,
       WalkCamera.PreferGravityUpForMoving, true);
     M2.Append(MenuPreferGravityUpForMoving);
     M2.Append(TMenuItem.Create('Change Gravity Up Vector ...',  124));
     M2.Append(TMenuItem.Create('Change Move Speed...', 205));
     M.Append(TMenuSeparator.Create);
     MenuIgnoreAllInputs := TMenuItemChecked.Create(
       'Disable normal navigation (VRML/X3D "NONE" navigation)',  210,
       WalkCamera.IgnoreAllInputs, true);
     M2.Append(MenuIgnoreAllInputs);
     M.Append(M2);
   MenuCollisionCheck := TMenuItemChecked.Create(
     '_Collision Detection',                   123, CtrlC,
       SceneAnimation.Collides, true);
   M.Append(MenuCollisionCheck);
   Result.Append(M);
 M := TMenu.Create('_Animation');
   MenuAnimationTimePlaying := TMenuItemChecked.Create(
     '_Playing / Paused',   220, CtrlP, AnimationTimePlaying, true);
   M.Append(MenuAnimationTimePlaying);
   M.Append(TMenuItem.Create('Rewind to Beginning', 221));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Playing Speed Slower or Faster (on display) ...', 222));
   M.Append(TMenuItem.Create('Playing Speed Slower or Faster (on loading) ...', 223));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItemChecked.Create('Process VRML/X3D Events ("off" pauses also animation)', 224, ProcessEventsWanted, true));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Precalculate Animation from VRML/X3D Events ...', 225));
   Result.Append(M);
 M := TMenu.Create('_Edit');
   MenuRemoveSelectedGeometry :=
     TMenuItem.Create('Remove _Geometry Node (containing selected triangle)', 36);
   M.Append(MenuRemoveSelectedGeometry);
   MenuRemoveSelectedFace :=
     TMenuItem.Create('Remove _Face (containing selected triangle)', 37);
   M.Append(MenuRemoveSelectedFace);
   M.Append(TMenuItem.Create(
     'Remove VRML/X3D Nodes with Name Matching ...', 34));
   M.Append(TMenuSeparator.Create);
   MenuMergeCloseVertexes := TMenuItem.Create(
     'Merge Close Vertexes (of node with selected triangle) ...', 730);
   M.Append(MenuMergeCloseVertexes);
   M.Append(TMenuSeparator.Create);
   MenuEditMaterial := TMenu.Create('_Edit Material (of node with selected triangle)');
     MenuEditMaterial.Append(TMenuItem.Create('Diffuse Color ...' , 710));
     MenuEditMaterial.Append(TMenuItem.Create('Specular Color ...', 720));
   M.Append(MenuEditMaterial);
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create(
     'Remove Normals Info from Scene (forces normals to be calculated)',
      31));
   M.Append(TMenuItem.Create('Mark All Shapes as '+
     'non-solid (disables any backface culling)', 32));
   M.Append(TMenuItem.Create('Mark All Faces as '+
     'non-convex (forces faces to be triangulated carefully)', 33));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Handle receiveShadows by shadow maps', 35));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create(
     'Simply Assign GLSL Shader to All Objects ...', 41));
   Result.Append(M);
 M := TMenu.Create('_Console');
   M.Append(TMenuItem.Create('Print VRML _Info nodes',        102));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Print Current Camera _Node (VRML 1.0)',   106));
   M.Append(TMenuItem.Create('Print Current Camera Node (VRML 2.0, X3D)',    107));
   M.Append(TMenuItem.Create('Print _rayhunter Command-line to Render This View', 105));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Print _Bounding Box (of whole animation)', 109));
   M.Append(TMenuItem.Create('Print Bounding Box (of current _animation frame)', 110));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Print Current Walk _Frustum', 108));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Print Statistics of Top _Collisions Octree (Based on Shapes)', 101));
   MenuSelectedOctreeStat := TMenuItem.Create('Print Statistics of _Collisions Octree Of Selected Shape (Based on Triangles)', 100);
   M.Append(MenuSelectedOctreeStat);
   M.Append(TMenuItem.Create('Print Statistics of Rendering Octree (Based on Shapes)', 103));
   Result.Append(M);
 M := TMenu.Create('_Display');
   M.Append(TMenuItem.Create('_Screenshot to image ...',         127, K_F5));
   M.Append(TMenuItem.Create('Screenshot to video / multiple images ...', 540));
   M.Append(TMenuItem.Create('Screenshot to _cube map (environment around Walk position) ...',  550));
   M.Append(TMenuItem.Create('Screenshot to cube map DDS (environment around Walk position) ...',  555));
   M.Append(TMenuItem.Create('Screenshot depth to grayscale image ...', 560));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('_Raytrace !',                   125, CtrlR));
   M.Append(TMenuItemChecked.Create('_Full Screen',           126, K_F11,
     Glw.FullScreen, true));
   Result.Append(M);
 M := TMenu.Create('_Help');
   M.Append(TMenuItemChecked.Create('Show Status _Text',           122, K_F1,
      ShowStatus, true));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('Scene Information',                  121));
   M.Append(TMenuItem.Create('Manifold Edges Information',         129));
   MenuSelectedInfo :=
     TMenuItem.Create('Selected Object Information',               171);
   M.Append(MenuSelectedInfo);
   MenuSelectedLightsInfo :=
     TMenuItem.Create('Selected Object Lights Information',        172);
   UpdateSelectedEnabled;
   M.Append(MenuSelectedLightsInfo);
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('OpenGL Information',                 173));
   M.Append(TMenuSeparator.Create);
   M.Append(TMenuItem.Create('About view3dscene',                  131));
   Result.Append(M);
end;

{ initializing GL context --------------------------------------------------- }

procedure MultiSamplingOff(Glwin: TGLWindow; const FailureMessage: string);
begin
  AntiAliasing := 0;
  if AntiAliasingMenu[AntiAliasing] <> nil then
    AntiAliasingMenu[AntiAliasing].Checked := true;
  Writeln(FailureMessage);
end;

procedure StencilOff(Glwin: TGLWindow; const FailureMessage: string);
begin
  ShadowsPossibleCurrently := false;
  Writeln(FailureMessage);
end;

{ Call Glw.Init, when anti-aliasing (multi-sampling) and shadows (stencil
  buffer) are possibly allowed. If EGLContextNotPossible, will try to lower
  requirements and initialize worse GL context. }
procedure InitContext;
begin
  Glw.InitOptionalMultiSamplingAndStencil(@MultiSamplingOff, @StencilOff);
end;

{ main --------------------------------------------------------------------- }

var
  Param_CameraRadius: Single = 0.0;
  WasParam_WriteToVRML: boolean = false;

  WasParam_SceneFileName: boolean = false;
  Param_SceneFileName: string;
  Param_SceneChanges: TSceneChanges = [];

const
  Options: array[0..12] of TOption =
  (
    (Short:  #0; Long: 'camera-radius'; Argument: oaRequired),
    (Short:  #0; Long: 'scene-change-no-normals'; Argument: oaNone),
    (Short:  #0; Long: 'scene-change-no-solid-objects'; Argument: oaNone),
    (Short:  #0; Long: 'scene-change-no-convex-faces'; Argument: oaNone),
    (Short:  #0; Long: 'write-to-vrml'; Argument: oaNone),
    (Short: 'h'; Long: 'help'; Argument: oaNone),
    (Short: 'v'; Long: 'version'; Argument: oaNone),
    (Short:  #0; Long: 'screenshot'; Argument: oaRequired2Separate),
    (Short:  #0; Long: 'screenshot-range'; Argument: oaRequired4Separate),
    (Short:  #0; Long: 'debug-log'; Argument: oaNone),
    (Short:  #0; Long: 'debug-log-vrml-changes'; Argument: oaNone),
    (Short:  #0; Long: 'anti-alias'; Argument: oaRequired),
    (Short: 'H'; Long: 'hide-extras'; Argument: oaNone)
  );

  procedure OptionProc(OptionNum: Integer; HasArgument: boolean;
    const Argument: string; const SeparateArgs: TSeparateArgs; Data: Pointer);
  var
    SingleScreenShot: TSingleScreenShot;
    RangeScreenShot: TRangeScreenShot;
  begin
   case OptionNum of
    0 : Param_CameraRadius := StrToFloat(Argument);
    1 : Include(Param_SceneChanges, scNoNormals);
    2 : Include(Param_SceneChanges, scNoSolidObjects);
    3 : Include(Param_SceneChanges, scNoConvexFaces);
    4 : WasParam_WriteToVRML := true;
    5 : begin
         InfoWrite(
           'view3dscene: VRML (1.0 and 2.0, aka VRML 97), Kanim,' +NL+
           '3DS, MD3, Wavefront OBJ and Collada viewer.' +NL+
           'You can move in the scene, possibly with collision-checking.' +NL+
           'It can also be used to convert models in other formats (3DS etc.) to VRML.' +NL+
           'It has built-in raytracer, similar to that available in "rayhunter".' +NL+
           NL+
           'Call as' +NL+
           '  view3dscene [OPTIONS]... FILE-TO-VIEW' +NL+
           NL+
           'Available options are:' +NL+
           HelpOptionHelp +NL+
           VersionOptionHelp +NL+
           '  -H / --hide-extras    Do not show anything extra (like status text' +NL+
           '                        or bounding box) when program starts.' +NL+
           '                        Show only the 3D world.' +NL+
           '  --camera-radius RADIUS' +NL+
           '                        Set camera sphere radius used for collisions' +NL+
           '                        and determinig moving speed' +NL+
           '  --scene-change-no-normals ,' +NL+
           '  --scene-change-no-solid-objects ,' +NL+
           '  --scene-change-no-convex-faces' +NL+
           '                        Change scene somehow after loading' +NL+
           '  --write-to-vrml       After loading (and changing) scene, write it' +NL+
           '                        as VRML 1.0 to the standard output' +NL+
           CamerasOptionsHelp +NL+
           VRMLNodesDetailOptionsHelp +NL+
           RendererOptimizationOptionsHelp +NL+
           '  --screenshot TIME IMAGE-FILE-NAME' +NL+
           '                        Take a screenshot of the loaded scene' +NL+
           '                        at given TIME, and save it to IMAGE-FILE-NAME.' +NL+
           '                        You most definitely want to pass 3D model' +NL+
           '                        file to load at command-line too, otherwise' +NL+
           '                        we''ll just make a screenshot of the default' +NL+
           '                        black scene.' +NL+
           '  --screenshot-range TIME-BEGIN TIME-STEP FRAMES-COUNT FILE-NAME' +NL+
           '                        Take a FRAMES-COUNT number of screenshots from' +NL+
           '                        TIME-BEGIN by step TIME-STEP. Save them to' +NL+
           '                        a single movie file (like .avi) (ffmpeg must' +NL+
           '                        be installed and available on $PATH for this)' +NL+
           '                        or to a sequence of image files (FILE-NAME' +NL+
           '                        must then be specified like image%d.png).' +NL+
           '  --anti-alias AMOUNT   Use full-screen anti-aliasing.' +NL+
           '                        Argument AMOUNT is an integer >= 0.' +NL+
           '                        Exact 0 means "no anti-aliasing",' +NL+
           '                        this is the default. Each successive integer' +NL+
           '                        generally makes method one step better.' +NL+
           NL+
           TGLWindow.ParseParametersHelp(StandardParseOptions, true) +NL+
           NL+
           'Debug options:' +NL+
           '  --debug-log           Write log info to stdout.' +NL+
           '  --debug-log-vrml-changes' +nl+
           '                        If --debug-log, output also info about' +NL+
           '                        VRML graph changes. This indicates' +nl+
           '                        how VRML events are optimized.' +nl+
           NL+
           SVrmlEngineProgramHelpSuffix(DisplayProgramName, Version, true));
         ProgramBreak;
        end;
    6 : begin
         Writeln(Version);
         ProgramBreak;
        end;
    7 : begin
          SingleScreenShot := TSingleScreenShot.Create;
          SingleScreenShot.Time := StrToFloat(SeparateArgs[1]);
          SingleScreenShot.FileNamePattern := SeparateArgs[2];
          ScreenShotsList.Add(SingleScreenShot);
        end;
    8 : begin
          RangeScreenShot := TRangeScreenShot.Create;
          RangeScreenShot.TimeBegin := StrToFloat(SeparateArgs[1]);
          RangeScreenShot.TimeStep := StrToFloat(SeparateArgs[2]);
          RangeScreenShot.FramesCount := StrToInt(SeparateArgs[3]);
          RangeScreenShot.FileNamePattern := SeparateArgs[4];
          ScreenShotsList.Add(RangeScreenShot);
        end;
    9 : InitializeLog(Version);
    10: begin
          InitializeLog(Version);
          DebugLogVRMLChanges := true;
        end;
    11: begin
          { for proper menu display, we have to keep AntiAliasing
            within 0..MaxAntiAliasing range (although GLAntiAliasing
            unit accepts any cardinal value). }
          AntiAliasing := Clamped(StrToInt(Argument), 0, MaxAntiAliasing);
          if AntiAliasingMenu[AntiAliasing] <> nil then
            AntiAliasingMenu[AntiAliasing].Checked := true;
        end;
    12: begin
          ShowBBox := false;
          ShowStatus := false;
        end;
    else raise EInternalError.Create('OptionProc');
   end;
  end;

begin
  Glw := TGLUIWindow.Create(Application);

  { parse parameters }
  { glw params }
  Glw.ParseParameters(StandardParseOptions);
  { our params }
  CamerasParseParameters;
  VRMLNodesDetailOptionsParse;
  RendererOptimizationOptionsParse(Optimization);
  ParseParameters(Options, @OptionProc, nil);
  { the most important param : filename to load }
  if Parameters.High > 1 then
   raise EInvalidParams.Create('Excessive command-line parameters. '+
     'Expected at most one filename to load') else
  if Parameters.High = 1 then
  begin
    WasParam_SceneFileName := true;
    Param_SceneFileName := Parameters[1];
  end;

  if ScreenShotsList.Count = 1 then
  begin
    { There's no point in using better optimization. They would waste
      time to prepare display lists, while we only render scene once. }
    Optimization := roNone;
    OptimizationSaveConfig := false;
  end;

  SceneManager := TV3DSceneManager.Create(nil);
  Glw.Controls.Add(SceneManager);
  SceneManager.OnBoundViewpointChanged := @THelper(nil).BoundViewpointChanged;

  SceneWarnings := TSceneWarnings.Create;
  try
    VRMLWarning := @DoVRMLWarning;
    DataWarning := @DoDataWarning;

    if WasParam_WriteToVRML then
    begin
      if not WasParam_SceneFileName then
        raise EInvalidParams.Create('You used --write-to-vrml option, '+
          'this means that you want to convert some 3d model file to VRML. ' +
          'But you didn''t provide any filename on command-line to load.');
      WriteToVRML(Param_SceneFileName, Param_SceneChanges);
      Exit;
    end;

    { This is for loading default clean scene.
      LoadClearScene should be lighting fast always,
      so progress should not be needed in this case anyway
      (and we don't want to clutter stdout). }
    Progress.UserInterface := ProgressNullInterface;

    { init "scene global variables" to null values }
    SceneAnimation := TVRMLGLAnimation.Create(nil);
    try
      SceneAnimation.Optimization := Optimization;
      SceneAnimation.Attributes.BlendingDestinationFactor := V3DDefaultBlendingDestinationFactor;
      SceneManager.Items.Add(SceneAnimation);

      InitCameras(SceneManager);
      InitColorModulator(SceneAnimation);
      InitTextureFilters(SceneAnimation);

      RecentMenu := TGLRecentFiles.Create(nil);
      RecentMenu.LoadFromConfig(ConfigFile, 'recent_files');
      RecentMenu.OnOpenRecent := @THelper(nil).OpenRecent;

      { init "scene global variables" to non-null values }
      LoadClearScene;
      try
        GLWinMessagesTheme := GLWinMessagesTheme_TypicalGUI;

        Glw.GtkIconName := 'view3dscene';
        Glw.MainMenu := CreateMainMenu;
        Glw.OnMenuCommand := @MenuCommand;
        Glw.OnInit := @Init;
        Glw.OnClose := @Close;
        Glw.OnMouseDown := @MouseDown;

        { For MakingScreenShot = true, leave OnDraw as @nil
          (it doesn't do anything anyway when MakingScreenShot = true). }
        if not MakingScreenShot then
        begin
          Glw.OnDraw := @Draw;
        end else
        begin
          { --geometry must work as reliably as possible in this case. }
          Glw.ResizeAllowed := raNotAllowed;

          { Do not show window on the screen, since we're working in batch mode. }
          Glw.WindowVisible := false;
        end;

        Glw.SetDemoOptions(K_None, #0, true);

        if ShadowsPossibleWanted then
        begin
          Glw.StencilBufferBits := 8;
          { Assignment below essentially copies
            ShadowsPossibleWanted to ShadowsPossibleCurrently.
            ShadowsPossibleCurrently may be eventually turned to @false
            by InitContext. }
          ShadowsPossibleCurrently := true;
        end;
        Assert(ShadowsPossibleCurrently = ShadowsPossibleWanted);

        Glw.MultiSampling := AntiAliasingGlwMultiSampling;

        InitContext;

        if WasParam_SceneFileName then
          LoadScene(Param_SceneFileName, Param_SceneChanges, Param_CameraRadius, true) else
          LoadWelcomeScene;

        if MakingScreenShot then
        begin
          MakeAllScreenShots;
          Exit;
        end;

        Application.Run;
      finally FreeScene end;
    finally
      FreeAndNil(SceneAnimation);
      if RecentMenu <> nil then
        RecentMenu.SaveToConfig(ConfigFile, 'recent_files');
      FreeAndNil(RecentMenu);
    end;
  finally
    FreeAndNil(SceneWarnings);
    FreeAndNil(SceneManager);
  end;
end.

{
  Local Variables:
  kam-compile-release-command-unix:    "./compile.sh && mv -fv view3dscene      ~/bin/"
  kam-compile-release-command-windows: "./compile.sh && mv -fv view3dscene.exe c:\\\\bin\\\\"
  End:
}
